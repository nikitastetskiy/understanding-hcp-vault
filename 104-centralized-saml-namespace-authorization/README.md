# Lab 104: Centralized authentication across Vault namespaces

This lab proves that users can authenticate once in a parent namespace and receive policies from
a child namespace without creating duplicate entities.

```text
PARENT: lab-104/

  Alice --> userpass login --> Alice entity --> application-a source group
                                                    |
                                                    | member_group_ids
                                                    v
CHILD: lab-104/team-a/                    application-a-readers
                                                    |
                                                    v
                                      application-a-read policy
                                                    |
                                                    v
                                      Application A secret
```

The parent answers **who is this user?** The child answers **what may this user do here?**

The local proof uses `userpass` and internal source groups so it works without an external identity
provider. The last section explains how SAML replaces these objects with external groups and group
aliases.

## What the objects mean

- **Parent entity:** A normal Vault entity stored where the auth method is mounted. "Parent" only
  describes its namespace location.
- **Source group:** A group in the parent namespace that represents identity-provider membership.
- **Child internal group:** A group in the child namespace that includes the parent group by ID.
- **Child policy:** The permissions granted by the child internal group.

## Requirements

- Complete the Docker setup in [`00-docker`](../00-docker/).
- Keep the resulting Compose environment in the repository's `vault/` directory.
- Vault Enterprise license with namespace support.
- Vault CLI, `curl`, and `jq`.

All commands below start from the repository root and use Vault's explicit `-namespace` flag. This
makes the target namespace visible in every command.

## 1. Start the existing Docker Vault

```bash
# Enter the directory containing your persistent Vault Compose environment.
cd vault

# Start the Vault Enterprise container created in Lab 00.
docker compose up -d

# Configure the local CLI for this TLS-enabled Vault server.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="$PWD/certs/vault.crt"

# Wait until the Vault API responds, even if Vault is still sealed.
until curl --silent --fail --cacert "$VAULT_CACERT" \
  "$VAULT_ADDR/v1/sys/health?standbyok=true&sealedcode=200" >/dev/null; do sleep 1; done

# Display the current seal state.
vault status
```

If `Sealed` is `true`, copy these commands. They read three unseal keys from the initialization file
created in Lab 00:

```bash
# Supply the first three unseal key shares.
vault operator unseal "$(grep 'Unseal Key 1:' certs/init.txt | cut -d' ' -f4)"
vault operator unseal "$(grep 'Unseal Key 2:' certs/init.txt | cut -d' ' -f4)"
vault operator unseal "$(grep 'Unseal Key 3:' certs/init.txt | cut -d' ' -f4)"
```

Load the existing root token:

```bash
# Keep a named copy because the lab switches between root and user tokens.
export ROOT_TOKEN="$(grep 'Initial Root Token:' certs/init.txt | cut -d' ' -f4)"
export VAULT_TOKEN="$ROOT_TOKEN"

# Confirm that the token works.
vault token lookup
```

## 2. Create a clean namespace hierarchy

The lab uses its own parent namespace, `lab-104/`. Deleting that namespace resets only this lab and
does not touch other Vault data.

```bash
# Remove the previous child namespace first. Ignore "no value found" on the first run.
vault namespace delete -namespace=lab-104 team-a

# Namespace deletion is asynchronous. Wait until the child disappears.
until ! vault namespace list -namespace=lab-104 2>/dev/null \
  | grep -q 'team-a/'; do sleep 1; done

# Remove the previous parent namespace.
vault namespace delete lab-104

# Wait until the parent namespace disappears.
until ! vault namespace list 2>/dev/null \
  | grep -q 'lab-104/'; do sleep 1; done

# Create a clean parent namespace for centralized authentication.
vault namespace create lab-104

# Create the child namespace where the application secrets and policies live.
vault namespace create -namespace=lab-104 team-a

# Verify the hierarchy.
vault namespace list
vault namespace list -namespace=lab-104
```

If either delete reports `No value found`, continue. It only means there was no previous lab.

## 3. Create the child secrets and policies

Every command explicitly targets `lab-104/team-a`.

```bash
# Enable KV v2 in the child namespace.
vault secrets enable -namespace=lab-104/team-a -path=secret kv-v2

# Store the Application A secret.
vault kv put -namespace=lab-104/team-a -mount=secret \
  application-a/config value="a-only"

# Store the Application B secret.
vault kv put -namespace=lab-104/team-a -mount=secret \
  application-b/config value="b-only"

# Write the Application A policy into the child namespace.
vault policy write -namespace=lab-104/team-a application-a-read \
  ../104-centralized-saml-namespace-authorization/policies/application-a-read.hcl

# Write the Application B policy into the child namespace.
vault policy write -namespace=lab-104/team-a application-b-read \
  ../104-centralized-saml-namespace-authorization/policies/application-b-read.hcl
```

`-mount=secret application-a/config` is the readable KV v2 syntax. Vault translates it to the API
path `secret/data/application-a/config`, which is why the policy contains `/data/`.

## 4. Create centralized users and entities

The auth method, users, entities, and aliases all live in the parent namespace `lab-104/`.

```bash
# Enable one shared userpass auth method in the parent namespace.
vault auth enable -namespace=lab-104 userpass

# Create Alice and Bob on that auth method.
vault write -namespace=lab-104 auth/userpass/users/alice \
  password="alice-password"
vault write -namespace=lab-104 auth/userpass/users/bob \
  password="bob-password"

# Read the unique accessor of the parent userpass mount.
USERPASS_ACCESSOR=$(vault auth list -namespace=lab-104 -format=json \
  | jq -r '.["userpass/"].accessor')

# Create Alice's parent entity.
ALICE_ENTITY_ID=$(vault write -namespace=lab-104 -field=id \
  identity/entity name="alice")

# Connect the Alice username on this auth mount to Alice's entity.
vault write -namespace=lab-104 identity/entity-alias \
  name="alice" \
  canonical_id="$ALICE_ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"

# Create Bob's parent entity.
BOB_ENTITY_ID=$(vault write -namespace=lab-104 -field=id \
  identity/entity name="bob")

# Connect the Bob username on this auth mount to Bob's entity.
vault write -namespace=lab-104 identity/entity-alias \
  name="bob" \
  canonical_id="$BOB_ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"
```

The entity is the identity Vault knows. The entity alias says, "this username on this exact auth
mount belongs to this entity."

## 5. Connect parent groups to child policies

The parent groups simulate groups returned by SAML. Alice belongs to Application A, and Bob belongs
to Application B.

```bash
# Create Alice's source group in the parent namespace.
ROOT_GROUP_A_ID=$(vault write -namespace=lab-104 -field=id identity/group \
  name="idp-application-a" \
  type="internal" \
  member_entity_ids="$ALICE_ENTITY_ID")

# Create Bob's source group in the parent namespace.
ROOT_GROUP_B_ID=$(vault write -namespace=lab-104 -field=id identity/group \
  name="idp-application-b" \
  type="internal" \
  member_entity_ids="$BOB_ENTITY_ID")

# Create a child group that includes the parent Application A group by ID.
vault write -namespace=lab-104/team-a identity/group \
  name="application-a-readers" \
  type="internal" \
  policies="application-a-read" \
  member_group_ids="$ROOT_GROUP_A_ID"

# Create a child group that includes the parent Application B group by ID.
vault write -namespace=lab-104/team-a identity/group \
  name="application-b-readers" \
  type="internal" \
  policies="application-b-read" \
  member_group_ids="$ROOT_GROUP_B_ID"
```

`member_group_ids` is the bridge. It makes every member of the parent source group an indirect
member of the child internal group. The child group then grants its local policy.

## 6. Authenticate once and test Alice

```bash
# Log Alice in where the centralized auth method exists.
ALICE_TOKEN=$(vault login -namespace=lab-104 -token-only -method=userpass \
  username="alice" password="alice-password")

# Use Alice's token for the next commands.
export VAULT_TOKEN="$ALICE_TOKEN"

# Allowed: Alice belongs to the Application A source group.
vault kv get -namespace=lab-104/team-a -mount=secret \
  application-a/config

# Denied: Alice does not belong to the Application B source group.
vault kv get -namespace=lab-104/team-a -mount=secret \
  application-b/config
```

The first read returns `a-only`. The second read returns HTTP `403 permission denied`. This failure
is expected and proves that the policies are isolated.

Inspect Alice's token:

```bash
# The token has one entity ID and a policy from the child namespace.
vault token lookup -namespace=lab-104 -format=json \
  | jq '{entity_id: .data.entity_id, child_policies: .data.external_namespace_policies}'
```

`external_namespace_policies` shows `application-a-read` under the ID of `lab-104/team-a/`. The
policy is "external" to the namespace that issued the token; it is not an external IdP policy.

## 7. Test Bob

```bash
# Return to the root token before performing Bob's login.
export VAULT_TOKEN="$ROOT_TOKEN"

# Log Bob in through the same centralized auth method.
BOB_TOKEN=$(vault login -namespace=lab-104 -token-only -method=userpass \
  username="bob" password="bob-password")

# Use Bob's token for the next commands.
export VAULT_TOKEN="$BOB_TOKEN"

# Allowed: Bob belongs to the Application B source group.
vault kv get -namespace=lab-104/team-a -mount=secret \
  application-b/config

# Denied: Bob does not belong to the Application A source group.
vault kv get -namespace=lab-104/team-a -mount=secret \
  application-a/config
```

The first read returns `b-only`; the second returns HTTP `403 permission denied`.

## 8. Prove there are no child entities

```bash
# Restore the administrator token.
export VAULT_TOKEN="$ROOT_TOKEN"

# The parent namespace contains exactly Alice and Bob.
vault list -namespace=lab-104 identity/entity/id

# The child namespace has no entities. "No value found" is the expected result.
vault list -namespace=lab-104/team-a identity/entity/id
```

The child groups reference parent groups. They do not copy Alice or Bob into the child namespace.

## How SAML changes the design

The namespace structure and child groups stay the same. In the parent namespace:

1. Replace `userpass` with one SAML auth mount.
2. Replace each simulated internal source group with an **external group**.
3. Add a **group alias** whose name exactly matches the group value in the SAML assertion.

```text
SAML assertion group value
          |
          v
group alias --mount_accessor--> SAML auth mount
          |
          v
parent external group
          |
          | member_group_ids
          v
child internal group --> child policy
```

Example after configuring SAML in the parent namespace:

```bash
# Read the SAML mount accessor from the parent namespace.
SAML_ACCESSOR=$(vault auth list -namespace=lab-104 -format=json \
  | jq -r '.["saml/"].accessor')

# Create Vault's representation of an IdP-managed group.
GROUP_A_ID=$(vault write -namespace=lab-104 -field=id identity/group \
  name="idp-application-a" \
  type="external")

# Map the exact SAML group value to that Vault external group.
vault write -namespace=lab-104 identity/group-alias \
  name="application-a-idp-group" \
  mount_accessor="$SAML_ACCESSOR" \
  canonical_id="$GROUP_A_ID"

# Grant the external group a policy owned by the child namespace.
vault write -namespace=lab-104/team-a identity/group \
  name="application-a-readers" \
  type="internal" \
  policies="application-a-read" \
  member_group_ids="$GROUP_A_ID"
```

At SAML login, the IdP reports the user's group values. Vault matches those values to group aliases,
calculates external-group membership, follows `member_group_ids` into the child internal group, and
adds the child policy to the token's effective permissions.

## Cleanup

```bash
# Restore the root token and remove only the Lab 104 namespace tree.
export VAULT_TOKEN="$ROOT_TOKEN"

# Vault requires deleting the child before its parent.
vault namespace delete -namespace=lab-104 team-a

# Wait for the asynchronous child deletion to finish.
until ! vault namespace list -namespace=lab-104 2>/dev/null \
  | grep -q 'team-a/'; do sleep 1; done

vault namespace delete lab-104

# Wait for the asynchronous parent deletion to finish.
until ! vault namespace list 2>/dev/null \
  | grep -q 'lab-104/'; do sleep 1; done

# Stop the existing Vault container without deleting its persistent data.
docker compose down

# Clear this terminal's Vault variables.
unset VAULT_ADDR VAULT_CACERT VAULT_TOKEN ROOT_TOKEN ALICE_TOKEN BOB_TOKEN
```

## Official HashiCorp documentation

- [Auth methods and Identity groups across namespaces][namespace-option]
- [Vault Identity: entities, aliases, and groups][identity]
- [SAML auth method][saml]
- [Link SAML groups to Vault external groups][saml-groups]
- [Identity group API][group-api]
- [Identity group alias API][group-alias-api]

[namespace-option]: https://developer.hashicorp.com/vault/tutorials/enterprise/namespaces#auth-methods-and-identity-groups
[identity]: https://developer.hashicorp.com/vault/docs/concepts/identity
[saml]: https://developer.hashicorp.com/vault/docs/auth/saml
[saml-groups]: https://developer.hashicorp.com/vault/docs/auth/saml/link-vault-group-to-ad
[group-api]: https://developer.hashicorp.com/vault/api-docs/secret/identity/group
[group-alias-api]: https://developer.hashicorp.com/vault/api-docs/secret/identity/group-alias
