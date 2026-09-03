#!/bin/sh
set -eu

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"
unset VAULT_NAMESPACE

LAB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "Waiting for Vault..."
attempt=0
until vault status >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Vault did not become ready at $VAULT_ADDR" >&2
    exit 1
  fi
  sleep 1
done

echo "Configuring namespaces and Team-A secrets..."
vault namespace create team-a >/dev/null
VAULT_NAMESPACE=team-a vault secrets enable -path=secret kv-v2 >/dev/null
VAULT_NAMESPACE=team-a vault kv put secret/application-a/config value=a-only >/dev/null
VAULT_NAMESPACE=team-a vault kv put secret/application-b/config value=b-only >/dev/null
VAULT_NAMESPACE=team-a vault policy write application-a-read "$LAB_DIR/policies/application-a-read.hcl" >/dev/null
VAULT_NAMESPACE=team-a vault policy write application-b-read "$LAB_DIR/policies/application-b-read.hcl" >/dev/null

echo "Configuring one root auth mount and canonical root entities..."
vault auth enable userpass >/dev/null
vault write auth/userpass/users/alice password=alice-password >/dev/null
vault write auth/userpass/users/bob password=bob-password >/dev/null
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '.["userpass/"].accessor')

ALICE_ENTITY_ID=$(vault write -field=id identity/entity name=alice)
vault write identity/entity-alias name=alice canonical_id="$ALICE_ENTITY_ID" mount_accessor="$USERPASS_ACCESSOR" >/dev/null
BOB_ENTITY_ID=$(vault write -field=id identity/entity name=bob)
vault write identity/entity-alias name=bob canonical_id="$BOB_ENTITY_ID" mount_accessor="$USERPASS_ACCESSOR" >/dev/null

echo "Creating root source groups and Team-A authorization groups..."
ROOT_GROUP_A_ID=$(vault write -field=id identity/group name=idp-application-a type=internal member_entity_ids="$ALICE_ENTITY_ID")
ROOT_GROUP_B_ID=$(vault write -field=id identity/group name=idp-application-b type=internal member_entity_ids="$BOB_ENTITY_ID")
VAULT_NAMESPACE=team-a vault write identity/group name=application-a-readers policies=application-a-read member_group_ids="$ROOT_GROUP_A_ID" >/dev/null
VAULT_NAMESPACE=team-a vault write identity/group name=application-b-readers policies=application-b-read member_group_ids="$ROOT_GROUP_B_ID" >/dev/null

ALICE_TOKEN=$(vault write -format=json auth/userpass/login/alice password=alice-password | jq -r '.auth.client_token')
BOB_TOKEN=$(vault write -format=json auth/userpass/login/bob password=bob-password | jq -r '.auth.client_token')

expect_allowed() {
  user=$1
  token=$2
  path=$3
  if output=$(VAULT_NAMESPACE=team-a VAULT_TOKEN="$token" vault kv get -field=value "$path" 2>&1); then
    printf 'PASS allowed: %s -> %s (%s)\n' "$user" "$path" "$output"
  else
    printf 'FAIL expected access: %s -> %s\n%s\n' "$user" "$path" "$output" >&2
    exit 1
  fi
}

expect_denied() {
  user=$1
  token=$2
  path=$3
  if output=$(VAULT_NAMESPACE=team-a VAULT_TOKEN="$token" vault kv get -field=value "$path" 2>&1); then
    printf 'FAIL unexpected access: %s -> %s (%s)\n' "$user" "$path" "$output" >&2
    exit 1
  fi
  printf '%s' "$output" | grep -q '403'
  printf 'PASS denied:  %s -> %s\n' "$user" "$path"
}

echo "Testing the authorization matrix..."
expect_allowed alice "$ALICE_TOKEN" secret/application-a/config
expect_denied alice "$ALICE_TOKEN" secret/application-b/config
expect_allowed bob "$BOB_TOKEN" secret/application-b/config
expect_denied bob "$BOB_TOKEN" secret/application-a/config

ALICE_TOKEN_DETAILS=$(VAULT_TOKEN="$ALICE_TOKEN" vault token lookup -format=json)
ALICE_LOGIN_ENTITY_ID=$(printf '%s' "$ALICE_TOKEN_DETAILS" | jq -r '.data.entity_id')
ALICE_HAS_CHILD_POLICY=$(printf '%s' "$ALICE_TOKEN_DETAILS" | jq -r 'any(.data.external_namespace_policies[]?[]?; . == "application-a-read")')
ROOT_ENTITY_COUNT=$(vault list -format=json identity/entity/id | jq 'length')
ALICE_CHILD_ENTITY_COUNT=$(VAULT_NAMESPACE=team-a vault list -format=json identity/entity/id 2>/dev/null | jq 'length' 2>/dev/null || printf '0')

test "$ALICE_LOGIN_ENTITY_ID" = "$ALICE_ENTITY_ID"
test "$ALICE_HAS_CHILD_POLICY" = "true"
test "$ROOT_ENTITY_COUNT" = "2"
test "$ALICE_CHILD_ENTITY_COUNT" = "0"

echo "PASS identity: Alice's login uses the one root entity and Team-A has no duplicate entity"
echo "Lab completed successfully."
