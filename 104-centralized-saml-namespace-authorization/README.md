# Lab 104: Centralized SAML authorization across Vault namespaces

This lab proves a powerful Vault pattern: authenticate once in a parent namespace, keep one entity
per user, and grant different policies in child namespaces through Identity groups.

```text
                         PARENT NAMESPACE (root or admin/)

  SAML IdP group --> group alias --> external group ---+
                                                       | member_group_ids
  User --> SAML login --> entity --> group membership  |
                                                       v
                         CHILD NAMESPACE (team-a/)

                     internal group --> local policy --> local secrets
```

The alias connects an IdP group name to a Vault external group. The child internal group includes
that external group by ID and applies a policy owned by the child namespace. No duplicate auth
mount or duplicate user entity is required.

## What you will prove

- Alice and Bob authenticate through one auth mount in the parent namespace.
- Each login resolves to one parent entity.
- `team-a/` owns its secrets, policies, and internal authorization groups.
- Alice can read only Application A; Bob can read only Application B.
- Parent identities receive child policies through cross-namespace group membership.

The local proof uses `userpass` and parent internal groups because SAML requires an external IdP
and a browser. The cross-namespace authorization mechanism is identical. The final section shows
how SAML external groups and aliases replace the simulated source groups.

## Requirements

- Docker and Docker Compose.
- Vault CLI and `jq`.
- A Vault Enterprise license file.
- Run the commands from this directory.

The server runs in disposable dev mode without TLS. Never use this configuration in production.

## 1. Start Vault

```bash
# Load the Enterprise license used by the container. Replace this path.
export VAULT_LICENSE="$(cat /secure/path/to/vault.hclic)"

# Start a clean Vault Enterprise dev server.
docker compose down --volumes
docker compose up -d

# Point the CLI at the lab server and use its dev root token.
export VAULT_ADDR="http://127.0.0.1:18200"
export VAULT_TOKEN="root"
unset VAULT_NAMESPACE

# Wait until Vault is ready.
until vault status >/dev/null 2>&1; do sleep 1; done
```

## 2. Create the child namespace and secrets

Everything here belongs to `team-a/`. This is the authorization boundary: the child namespace
owns both the data and the policies that protect it.

```bash
# Create the child namespace from root.
vault namespace create team-a

# Enable one KV v2 secrets engine inside team-a/.
VAULT_NAMESPACE=team-a vault secrets enable -path=secret kv-v2

# Add two secrets to prove both allowed and denied access.
VAULT_NAMESPACE=team-a vault kv put secret/application-a/config value="a-only"
VAULT_NAMESPACE=team-a vault kv put secret/application-b/config value="b-only"

# Write both policies into team-a/, not root.
VAULT_NAMESPACE=team-a vault policy write application-a-read \
  policies/application-a-read.hcl
VAULT_NAMESPACE=team-a vault policy write application-b-read \
  policies/application-b-read.hcl
```

KV v2 policies use `secret/data/...`, while CLI commands use `secret/...`. The policy files already
contain the correct API paths.

## 3. Create one parent authentication source

Both users authenticate at root because that is where the auth method lives. We explicitly create
their entities and aliases so the one-login-to-one-entity relationship is visible.

```bash
# Enable one auth mount in the parent namespace.
vault auth enable userpass

# Create two users on that single mount.
vault write auth/userpass/users/alice password="alice-password"
vault write auth/userpass/users/bob password="bob-password"

# Read the mount accessor used to bind aliases to this exact auth mount.
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '.["userpass/"].accessor')

# Create Alice's canonical entity and connect her userpass username to it.
ALICE_ENTITY_ID=$(vault write -field=id identity/entity name="alice")
vault write identity/entity-alias \
  name="alice" \
  canonical_id="$ALICE_ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"

# Create Bob's canonical entity and connect his userpass username to it.
BOB_ENTITY_ID=$(vault write -field=id identity/entity name="bob")
vault write identity/entity-alias \
  name="bob" \
  canonical_id="$BOB_ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"
```

An entity is the person Vault recognizes. An entity alias connects that person to one account on
one auth mount. Centralizing the auth mount gives each user one stable parent identity.

## 4. Connect parent identity to child authorization

The two root groups simulate groups returned by a SAML IdP. The key operation is
`member_group_ids`: a child internal group can include a group created in its parent namespace.

```bash
# Simulate the IdP saying Alice belongs to Application A.
ROOT_GROUP_A_ID=$(vault write -field=id identity/group \
  name="idp-application-a" \
  type="internal" \
  member_entity_ids="$ALICE_ENTITY_ID")

# Simulate the IdP saying Bob belongs to Application B.
ROOT_GROUP_B_ID=$(vault write -field=id identity/group \
  name="idp-application-b" \
  type="internal" \
  member_entity_ids="$BOB_ENTITY_ID")

# team-a/ maps parent group A to its local Application A policy.
VAULT_NAMESPACE=team-a vault write identity/group \
  name="application-a-readers" \
  type="internal" \
  policies="application-a-read" \
  member_group_ids="$ROOT_GROUP_A_ID"

# team-a/ maps parent group B to its local Application B policy.
VAULT_NAMESPACE=team-a vault write identity/group \
  name="application-b-readers" \
  type="internal" \
  policies="application-b-read" \
  member_group_ids="$ROOT_GROUP_B_ID"
```

This is the core of the design. Root answers **who the user is and which source groups they belong
to**. `team-a/` answers **what those groups may do here**.

## 5. Log in once and prove authorization

```bash
# Authenticate both users where the shared auth mount exists.
ALICE_TOKEN=$(vault login -field=token -method=userpass \
  username="alice" password="alice-password")
BOB_TOKEN=$(vault login -field=token -method=userpass \
  username="bob" password="bob-password")

# Alice can read Application A.
VAULT_NAMESPACE=team-a VAULT_TOKEN="$ALICE_TOKEN" \
  vault kv get -field=value secret/application-a/config

# Alice cannot read Application B. The command must return HTTP 403.
if VAULT_NAMESPACE=team-a VAULT_TOKEN="$ALICE_TOKEN" \
  vault kv get secret/application-b/config 2>&1 | grep -q "403"; then
  echo "PASS: Alice cannot read Application B"
else
  echo "FAIL: Alice unexpectedly read Application B"; false
fi

# Bob can read Application B.
VAULT_NAMESPACE=team-a VAULT_TOKEN="$BOB_TOKEN" \
  vault kv get -field=value secret/application-b/config

# Bob cannot read Application A. The command must return HTTP 403.
if VAULT_NAMESPACE=team-a VAULT_TOKEN="$BOB_TOKEN" \
  vault kv get secret/application-a/config 2>&1 | grep -q "403"; then
  echo "PASS: Bob cannot read Application A"
else
  echo "FAIL: Bob unexpectedly read Application A"; false
fi
```

Expected output includes:

```text
a-only
PASS: Alice cannot read Application B
b-only
PASS: Bob cannot read Application A
```

## 6. Prove there are no duplicate entities

The token was issued at root, but its child policy appears under `external_namespace_policies`.
That policy is evaluated when the same token targets `team-a/`.

```bash
# Alice's login must resolve to the entity created at root.
ALICE_LOGIN_ENTITY_ID=$(VAULT_TOKEN="$ALICE_TOKEN" \
  vault token lookup -field=entity_id)
test "$ALICE_LOGIN_ENTITY_ID" = "$ALICE_ENTITY_ID"

# Display the policy inherited from the team-a/ internal group.
VAULT_TOKEN="$ALICE_TOKEN" vault token lookup -format=json \
  | jq '.data.external_namespace_policies'

# Root contains exactly Alice and Bob.
test "$(vault list -format=json identity/entity/id | jq 'length')" -eq 2

# team-a/ contains no copied entities.
CHILD_ENTITY_COUNT=$(VAULT_NAMESPACE=team-a vault list -format=json \
  identity/entity/id 2>/dev/null | jq 'length' 2>/dev/null || printf '0')
test "$CHILD_ENTITY_COUNT" -eq 0

echo "PASS: one parent entity per user and no duplicate child entities"
```

The result works because Vault Identity groups can include entities and groups from other
namespaces. Authentication remains centralized, while authorization remains local and delegated.

## Use SAML instead of the simulation

In a real SAML setup, keep steps 2, 5, and 6 conceptually unchanged. Replace the `userpass` mount
and simulated root internal groups with one SAML mount, external groups, and aliases.

This section is a deployment template rather than part of the local proof. Replace the example
URLs, subjects, group attribute, and group names with values from the IdP application.

```bash
# HCP Vault Dedicated uses admin/ as the accessible top-level namespace.
# For self-managed Vault Enterprise root, leave VAULT_NAMESPACE unset.
export VAULT_NAMESPACE="admin"

# Enable SAML once in the parent namespace.
vault auth enable saml

# Configure the IdP metadata and namespace-aware callback URL.
vault write auth/saml/config \
  default_role="employees" \
  idp_metadata_url="https://idp.example.com/app/vault/metadata" \
  entity_id="https://vault.example.com/v1/admin/auth/saml" \
  acs_urls="https://vault.example.com/v1/admin/auth/saml/callback" \
  validate_response_signature=true \
  validate_assertion_signature=true

# Tell Vault which SAML assertion attribute contains group memberships.
vault write auth/saml/role/employees \
  bound_subjects="*@example.com" \
  bound_subjects_type="glob" \
  groups_attribute="groups" \
  token_ttl="1h"

# Read the accessor that makes each group alias specific to this SAML mount.
SAML_ACCESSOR=$(vault auth list -format=json | jq -r '.["saml/"].accessor')

# Create the Vault representation of the IdP's Application A group.
GROUP_A_ID=$(vault write -field=id identity/group \
  name="idp-application-a" \
  type="external")

# The alias name must exactly match the group value in the SAML assertion.
vault write identity/group-alias \
  name="application-a-idp-group" \
  mount_accessor="$SAML_ACCESSOR" \
  canonical_id="$GROUP_A_ID"

# Create and connect the IdP's Application B group in the same way.
GROUP_B_ID=$(vault write -field=id identity/group \
  name="idp-application-b" \
  type="external")
vault write identity/group-alias \
  name="application-b-idp-group" \
  mount_accessor="$SAML_ACCESSOR" \
  canonical_id="$GROUP_B_ID"

# Create team-a/ below admin/ and configure its local secrets and policies.
vault namespace create team-a
VAULT_NAMESPACE=admin/team-a vault secrets enable -path=secret kv-v2
VAULT_NAMESPACE=admin/team-a vault policy write application-a-read \
  policies/application-a-read.hcl
VAULT_NAMESPACE=admin/team-a vault policy write application-b-read \
  policies/application-b-read.hcl

# Attach the child policies to the parent groups.
VAULT_NAMESPACE=admin/team-a vault write identity/group \
  name="application-a-readers" \
  type="internal" \
  policies="application-a-read" \
  member_group_ids="$GROUP_A_ID"
VAULT_NAMESPACE=admin/team-a vault write identity/group \
  name="application-b-readers" \
  type="internal" \
  policies="application-b-read" \
  member_group_ids="$GROUP_B_ID"

# Authenticate where SAML is mounted, then use the token in its child namespace.
VAULT_NAMESPACE=admin vault login -method=saml role="employees"
export VAULT_NAMESPACE="admin/team-a"
vault kv get secret/application-a/config
```

For self-managed Vault Enterprise at root, omit `VAULT_NAMESPACE=admin` and remove `/admin` from
the SAML `entity_id` and `acs_urls`. The IdP must register the same ACS URL configured in Vault.

Vault updates effective external-group membership during login and token renewal. If the IdP
removes a user from a group, the change is therefore observed on the next login or renewal, not
immediately on an already issued token.

## Cleanup

```bash
# Remove the disposable server and clear lab variables.
docker compose down --volumes
unset VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE VAULT_LICENSE
```

## Official HashiCorp documentation

- [Auth methods and Identity groups across namespaces][namespace-option]
- [Vault Identity: entities, aliases, and groups][identity]
- [SAML auth method and namespace callback URLs][saml]
- [Link SAML groups to Vault external groups][saml-groups]
- [Identity group API][group-api]
- [Identity group alias API][group-alias-api]

[namespace-option]: https://developer.hashicorp.com/vault/tutorials/enterprise/namespaces#auth-methods-and-identity-groups
[identity]: https://developer.hashicorp.com/vault/docs/concepts/identity
[saml]: https://developer.hashicorp.com/vault/docs/auth/saml
[saml-groups]: https://developer.hashicorp.com/vault/docs/auth/saml/link-vault-group-to-ad
[group-api]: https://developer.hashicorp.com/vault/api-docs/secret/identity/group
[group-alias-api]: https://developer.hashicorp.com/vault/api-docs/secret/identity/group-alias
