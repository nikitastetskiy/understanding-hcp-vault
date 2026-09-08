#!/bin/sh
set -eu

LAB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:18201}
VAULT_TOKEN=${VAULT_TOKEN:-root}
ELASTIC_URL=${ELASTIC_URL:-http://127.0.0.1:19200}
KIBANA_URL=${KIBANA_URL:-http://127.0.0.1:15601}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-elastic-lab-password}
export VAULT_ADDR VAULT_TOKEN
unset VAULT_NAMESPACE

wait_for_url() {
  name=$1
  url=$2
  attempts=$3
  while [ "$attempts" -gt 0 ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 2
  done
  printf 'FAIL: %s did not become ready at %s\n' "$name" "$url" >&2
  return 1
}

wait_for_count() {
  data_stream=$1
  query=$2
  minimum=$3
  attempts=45
  while [ "$attempts" -gt 0 ]; do
    count=$(curl -fsS -u "elastic:$ELASTIC_PASSWORD" -H 'Content-Type: application/json' \
      "$ELASTIC_URL/logs-$data_stream-*/_count" \
      -d "{\"query\":$query}" 2>/dev/null | jq -r '.count // 0' || true)
    if [ "${count:-0}" -ge "$minimum" ]; then
      printf '%s\n' "$count"
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 2
  done
  return 1
}

wait_for_audit_count() {
  query=$1
  minimum=$2
  wait_for_count hashicorp_vault.audit "$query" "$minimum"
}

attempts=60
until curl -fsS -u "elastic:$ELASTIC_PASSWORD" "$ELASTIC_URL" >/dev/null 2>&1; do
  attempts=$((attempts - 1))
  if [ "$attempts" -eq 0 ]; then
    printf 'FAIL: authenticated Elasticsearch endpoint did not become ready\n' >&2
    exit 1
  fi
  sleep 2
done
wait_for_url Kibana "$KIBANA_URL/api/status" 90
wait_for_url Vault "$VAULT_ADDR/v1/sys/health" 60

curl -fsS -u "elastic:$ELASTIC_PASSWORD" -X POST -H 'kbn-xsrf: true' \
  "$KIBANA_URL/api/fleet/epm/packages/hashicorp_vault/1.31.0" >/dev/null

# Match HashiCorp's tutorial: TCP to Elastic plus a local file device.
vault audit enable -path=elastic-socket socket \
  description="TCP audit stream to Elastic Agent" \
  address=elastic-agent:9007 socket_type=tcp >/dev/null
vault audit enable -path=local-file file \
  description="Durable local audit copy" \
  file_path=/vault/logs/vault-audit.json >/dev/null

vault kv put secret/application/config value=production >/dev/null
vault policy write reader "$LAB_DIR/policies/reader.hcl" >/dev/null
vault auth enable userpass >/dev/null
vault write auth/userpass/users/analyst password=correct-password policies=reader >/dev/null

ANALYST_TOKEN=$(vault login -field=token -method=userpass \
  username=analyst password=correct-password)
ANALYST_ENTITY_ID=$(VAULT_TOKEN=$ANALYST_TOKEN vault token lookup -format=json \
  | jq -r '.data.entity_id')
test -n "$ANALYST_ENTITY_ID"
VAULT_TOKEN=$ANALYST_TOKEN vault kv get -field=value secret/application/config >/dev/null

# Generate the same incident classes emphasized by the official tutorial.
if vault login -method=userpass username=analyst password=wrong-password >/dev/null 2>&1; then
  printf 'FAIL: invalid password unexpectedly authenticated\n' >&2
  exit 1
fi
if VAULT_TOKEN=$ANALYST_TOKEN vault kv get secret/not-authorized >/dev/null 2>&1; then
  printf 'FAIL: unauthorized secret read unexpectedly succeeded\n' >&2
  exit 1
fi

audit_list=$(vault audit list -format=json)
test "$(printf '%s' "$audit_list" | jq 'length')" -eq 2
printf 'PASS Vault: two audit devices are enabled (TCP socket and file)\n'

docker compose -f "$LAB_DIR/docker-compose.yml" exec -T vault \
  sh -c 'test -s /vault/logs/vault-audit.json'
printf 'PASS file: Vault appended JSON audit records to the local file device\n'

login_query='{"bool":{"filter":[{"term":{"hashicorp_vault.audit.request.path":"auth/userpass/login/analyst"}},{"term":{"event.outcome":"failure"}}]}}'
if login_count=$(wait_for_audit_count "$login_query" 1); then
  printf 'PASS Elastic: indexed %s failed userpass audit event(s)\n' "$login_count"
else
  printf 'FAIL: failed userpass event was not indexed by Elastic\n' >&2
  exit 1
fi

denied_query='{"bool":{"filter":[{"term":{"event.outcome":"failure"}},{"term":{"hashicorp_vault.audit.request.path":"secret/data/not-authorized"}}]}}'
if denied_count=$(wait_for_audit_count "$denied_query" 1); then
  printf 'PASS Elastic: indexed %s permission-denied audit event(s)\n' "$denied_count"
else
  printf 'FAIL: permission-denied event was not indexed by Elastic\n' >&2
  exit 1
fi

entity_query=$(jq -cn --arg entity_id "$ANALYST_ENTITY_ID" \
  '{bool:{filter:[{term:{"hashicorp_vault.audit.auth.entity_id":$entity_id}},{term:{"hashicorp_vault.audit.request.client_id":$entity_id}}]}}')
if entity_count=$(wait_for_audit_count "$entity_query" 1); then
  printf 'PASS Elastic: attributed %s audit event(s) to entity/client %s\n' \
    "$entity_count" "$ANALYST_ENTITY_ID"
else
  printf 'FAIL: analyst activity was not attributable by entity_id/client_id\n' >&2
  exit 1
fi

if operational_count=$(wait_for_count hashicorp_vault.log '{"match_all":{}}' 1); then
  printf 'PASS Elastic: indexed %s Vault operational log event(s)\n' "$operational_count"
else
  printf 'FAIL: Vault operational events were not indexed by Elastic\n' >&2
  exit 1
fi

# Prove that one healthy device is sufficient when the TCP destination is down.
docker compose -f "$LAB_DIR/docker-compose.yml" stop elastic-agent >/dev/null
set +e
vault kv put secret/audit-fallback value=file-device-kept-vault-available >/dev/null 2>&1
fallback_status=$?
set -e
docker compose -f "$LAB_DIR/docker-compose.yml" start elastic-agent >/dev/null
if [ "$fallback_status" -ne 0 ]; then
  printf 'FAIL: Vault stopped serving while the file audit device was still available\n' >&2
  exit 1
fi
docker compose -f "$LAB_DIR/docker-compose.yml" exec -T vault \
  sh -c "grep -q '\"path\":\"secret/data/audit-fallback\"' /vault/logs/vault-audit.json"
printf 'PASS resilience: Vault served a request through the file device while TCP was down\n'
printf 'Lab completed successfully. Kibana: %s\n' "$KIBANA_URL"
