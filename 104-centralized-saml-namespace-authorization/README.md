# Centralized SAML identity with namespace-local authorization

## Customer question and answer

The supported architecture is:

```text
SAML identity provider
  -> SAML auth method in root (or HCP Vault Dedicated admin/)
  -> one root entity per user
  -> root external groups mapped to SAML group attributes
  -> namespace-local internal groups containing those root groups by ID
  -> namespace-local policies attached to the internal groups
```

Vault Identity groups can include entities and groups from other namespaces. Therefore, a team
namespace does **not** need a second entity for each user. It can own an internal group and a local
policy, while the internal group refers to a root external group through `member_group_ids`.

This is HashiCorp's documented "Option 2": configure authentication at root and use Identity
groups to map policies in each namespace. See [Auth methods and identity groups][namespace-option].

Identity templating is not required for this problem. Policy templates are useful when paths are
derived from entity or group metadata, but the customer needs group-to-policy mapping across
namespace boundaries.

## Why this removes duplicates

An entity alias is identified by its alias name plus the auth mount accessor. With one SAML mount,
each user authenticates through one accessor and resolves to one root entity. Enabling SAML again
inside each team namespace would introduce different mount accessors and allow separate entities
to be created. See [Entities, aliases, and mount-bound aliases][identity-entities].

The namespace-local internal groups are authorization objects, not copies of users. They can nest
the root group IDs and apply local policies dynamically when the user's token is used.

## Example design

| Object | Namespace | Purpose |
|---|---|---|
| `saml/` auth method | root | Central login and entity creation |
| `idp-application-a` external group | root | Alias for the IdP's Application A group |
| `idp-application-b` external group | root | Alias for the IdP's Application B group |
| `application-a-readers` internal group | `team-a/` | Nests root group A and carries `application-a-read` |
| `application-b-readers` internal group | `team-a/` | Nests root group B and carries `application-b-read` |
| `application-a-read` policy | `team-a/` | Allows only `secret/data/application-a/*` |
| `application-b-read` policy | `team-a/` | Allows only `secret/data/application-b/*` |

The policies remain owned by Team-A. Root manages authentication and IdP-to-Vault group mapping.
This separates identity administration from delegated authorization administration.

## Prerequisites

- Vault Enterprise or HCP Vault Dedicated. Namespaces and SAML are Enterprise features.
- Vault CLI and `jq`.
- Docker and Docker Compose for the local proof.
- A Vault Enterprise license in `VAULT_LICENSE` for the local container.

The Docker proof uses a root `userpass` mount instead of SAML so it can run without a browser and
external IdP. It verifies the relevant Vault primitives: root-issued tokens, one root entity,
cross-namespace group nesting, namespace-local policies, and denied cross-application access.
The production section replaces only the source auth method and source groups.

## Run the Docker proof

Run all commands from this directory.

```bash
export VAULT_LICENSE="$(cat /secure/path/to/vault.hclic)"
docker compose up -d
export VAULT_ADDR=http://127.0.0.1:18200
export VAULT_TOKEN=root
./run-lab.sh
```

Expected result:

```text
PASS allowed: alice -> secret/application-a/config (a-only)
PASS denied:  alice -> secret/application-b/config
PASS allowed: bob -> secret/application-b/config (b-only)
PASS denied:  bob -> secret/application-a/config
PASS identity: Alice's login uses the one root entity and Team-A has no duplicate entity
Lab completed successfully.
```

The lab uses a disposable dev server. Do not use dev mode in production.
`run-lab.sh` waits up to 30 seconds for Vault, but otherwise expects a fresh server. If a run is
interrupted, reset the disposable environment before retrying:

```bash
docker compose down --volumes
docker compose up -d
./run-lab.sh
```

### What the proof configures

The essential cross-namespace commands in `run-lab.sh` are:

```bash
# Source group at root. The lab uses an internal group to simulate IdP membership.
ROOT_GROUP_A_ID=$(vault write -field=id identity/group \
  name=idp-application-a \
  type=internal \
  member_entity_ids="$ALICE_ENTITY_ID")

# Authorization group and policy live in Team-A.
VAULT_NAMESPACE=team-a vault write identity/group \
  name=application-a-readers \
  policies=application-a-read \
  member_group_ids="$ROOT_GROUP_A_ID"
```

`member_group_ids` accepts a group UUID, so the child group can refer to the group created at
root. The [Identity group API][group-api] documents this field, and the [namespace tutorial's
root-auth example][namespace-option] demonstrates this exact parent-group-to-child-group pattern.

Inspect Alice's token from the lab:

```bash
ALICE_TOKEN=$(vault login -field=token -method=userpass \
  username=alice password=alice-password)
VAULT_TOKEN="$ALICE_TOKEN" vault token lookup
```

The child policy is shown under `external_namespace_policies`, keyed by the Team-A namespace ID.
The token remains tied to root, where authentication occurred, and is used against the child by
setting `VAULT_NAMESPACE=team-a`. This is expected namespace behavior, not token duplication.

Clean up:

```bash
docker compose down --volumes
unset VAULT_ADDR VAULT_TOKEN VAULT_LICENSE
```

## Configure the production SAML pattern

The commands in steps 1 through 5 assume self-managed Vault Enterprise with SAML mounted at root.
The HCP Vault Dedicated differences are listed after those steps.

### 1. Configure SAML once

```bash
unset VAULT_NAMESPACE
vault auth enable saml

vault write auth/saml/config \
  default_role=employees \
  idp_metadata_url="https://idp.example.com/app/vault/metadata" \
  entity_id="https://vault.example.com/v1/auth/saml" \
  acs_urls="https://vault.example.com/v1/auth/saml/callback" \
  validate_response_signature=true \
  validate_assertion_signature=true

vault write auth/saml/role/employees \
  bound_subjects="*@example.com" \
  bound_subjects_type=glob \
  groups_attribute=groups \
  token_ttl=1h
```

`groups_attribute` must name the SAML assertion attribute containing the user's groups. Vault uses
its values as Identity group alias names. If Microsoft Entra ID emits group object IDs under its
URI claim, use that full URI as `groups_attribute` and use group object IDs as the alias names.
The exact SAML fields are documented in the [SAML role API][saml-api].

Microsoft Entra ID can emit a group-overage indicator instead of group values when a user exceeds
the SAML token's group limit. Vault cannot match external-group aliases when the assertion omits
those values. Account for this in the IdP application design and test users with many memberships.

Do not attach broad child access policies to the shared SAML role. Let Identity groups supply the
team-specific policies.

### 2. Create root external groups and aliases

```bash
SAML_ACCESSOR=$(vault auth list -format=json | jq -r '.["saml/"].accessor')

GROUP_A_ID=$(vault write -field=id identity/group \
  name=idp-application-a type=external)
vault write identity/group-alias \
  name="application-a-idp-group" \
  mount_accessor="$SAML_ACCESSOR" \
  canonical_id="$GROUP_A_ID"

GROUP_B_ID=$(vault write -field=id identity/group \
  name=idp-application-b type=external)
vault write identity/group-alias \
  name="application-b-idp-group" \
  mount_accessor="$SAML_ACCESSOR" \
  canonical_id="$GROUP_B_ID"
```

Each alias name must exactly match the value emitted in the configured SAML group attribute. An
external group has one alias, and Vault updates its effective membership during login or token
renewal. Removal at the IdP is therefore not reflected in an already issued token until a later
login or renewal. See [External versus internal groups][external-groups] and HashiCorp's [SAML
group linking guide][saml-groups].

### 3. Create the namespace-local policies

```bash
vault namespace create team-a
VAULT_NAMESPACE=team-a vault secrets enable -path=secret kv-v2

VAULT_NAMESPACE=team-a vault policy write application-a-read \
  policies/application-a-read.hcl
VAULT_NAMESPACE=team-a vault policy write application-b-read \
  policies/application-b-read.hcl
```

KV v2 ACL paths include `/data/`; the CLI's logical path does not. For example, the policy grants
`secret/data/application-a/*`, while a user runs `vault kv get secret/application-a/config`.

### 4. Nest the root groups into Team-A groups

```bash
VAULT_NAMESPACE=team-a vault write identity/group \
  name=application-a-readers \
  policies=application-a-read \
  member_group_ids="$GROUP_A_ID"

VAULT_NAMESPACE=team-a vault write identity/group \
  name=application-b-readers \
  policies=application-b-read \
  member_group_ids="$GROUP_B_ID"
```

Repeat this step in each team namespace, choosing local policies appropriate to that namespace.
The same root external group can be nested into different local groups with different policies.

### 5. Authenticate at root and target Team-A

```bash
unset VAULT_NAMESPACE
vault login -method=saml role=employees

export VAULT_NAMESPACE=team-a
vault kv get secret/application-a/config
vault kv get secret/application-b/config
```

A user in only the Application A IdP group should pass the first read and receive HTTP 403 for the
second. `vault token lookup` should list Team-A's policy in `external_namespace_policies`.

### HCP Vault Dedicated differences

HCP Vault Dedicated exposes `admin/` as the top-level administrative namespace instead of giving
customers access to the true root. Configure the centralized objects while targeting `admin/`:

```bash
export VAULT_NAMESPACE=admin
vault auth enable saml

vault write auth/saml/config \
  default_role=employees \
  idp_metadata_url="https://idp.example.com/app/vault/metadata" \
  entity_id="https://vault.example.com/v1/admin/auth/saml" \
  acs_urls="https://vault.example.com/v1/admin/auth/saml/callback" \
  validate_response_signature=true \
  validate_assertion_signature=true
```

Run the role, accessor, external-group, and group-alias commands from steps 1 and 2 with
`VAULT_NAMESPACE=admin`. Create Team-A beneath it and use either relative or absolute context:

```bash
# Relative while the CLI context is admin/.
vault namespace create team-a
VAULT_NAMESPACE=admin/team-a vault policy write application-a-read \
  policies/application-a-read.hcl

# Authenticate where the mount exists, then target its child.
VAULT_NAMESPACE=admin vault login -method=saml role=employees
export VAULT_NAMESPACE=admin/team-a
vault kv get secret/application-a/config
```

The IdP application must also register the `https://vault.example.com/v1/admin/auth/saml/callback`
ACS URL. HashiCorp documents the required namespace segment under [SAML configuration for
namespaces][saml-namespaces].

## Policy application mode

For root authentication and descendant team namespaces, keep the default:

```bash
vault read sys/config/group-policy-application
# group_policy_application_mode = within_namespace_hierarchy
```

The default supports this root-to-descendant design. `any` is needed only when group policies must
apply to tokens issued in unrelated namespace hierarchies. It is a cluster-wide setting that
broadens cross-namespace policy application, so do not enable it for this use case without a
separate requirement and security review. See [Configure cross-namespace access][cross-ns].

## Operational boundaries

- Users must log in where SAML is mounted. A root auth mount does not become a child-local mount.
- A root-issued token targets a child with `VAULT_NAMESPACE`, `-namespace`, or the
  `X-Vault-Namespace` API header.
- Give team administrators control of their local policies and local internal groups only if that
  delegation is intended.
- Restrict all write access to Identity entities, aliases, groups, and memberships. HashiCorp warns
  that these permissions can be used for privilege escalation.
- Use immutable IdP group identifiers when available, especially if display names can change.
- Test group removal and token renewal behavior against the customer's IdP and token TTLs.
- Pin documentation URLs to the customer's deployed Vault version during implementation.

## Alternative architecture

Root policies can use fully qualified child paths, such as
`team-a/secret/data/application-a/*`, and be attached to root groups. That is supported but makes
root own all authorization. Namespace-local groups and policies are preferable when each team must
manage its own fine-grained controls.

## Official documentation

- [Secure multi-tenancy with namespaces][namespace-tutorial]
- [Root auth method plus namespace Identity groups, documented Option 2][namespace-option]
- [Vault Identity concepts][identity-groups]
- [SAML auth method][saml-docs]
- [SAML API, including `groups_attribute`][saml-api]
- [Link SAML groups to Vault external groups][saml-groups]
- [Identity group API][group-api]
- [Cross-namespace group policy application][cross-ns]
- [Vault API and namespace routing][namespace-api]

[namespace-tutorial]: https://developer.hashicorp.com/vault/tutorials/enterprise/namespaces
[namespace-option]: https://developer.hashicorp.com/vault/tutorials/enterprise/namespaces#auth-methods-and-identity-groups
[identity-groups]: https://developer.hashicorp.com/vault/docs/concepts/identity#identity-groups
[identity-entities]: https://developer.hashicorp.com/vault/docs/concepts/identity#entities-and-aliases
[external-groups]: https://developer.hashicorp.com/vault/docs/concepts/identity#external-vs-internal-groups
[group-api]: https://developer.hashicorp.com/vault/api-docs/secret/identity/group#create-a-group
[saml-docs]: https://developer.hashicorp.com/vault/docs/auth/saml
[saml-namespaces]: https://developer.hashicorp.com/vault/docs/auth/saml#configuration-for-namespaces
[saml-api]: https://developer.hashicorp.com/vault/api-docs/auth/saml#create-or-update-role
[saml-groups]: https://developer.hashicorp.com/vault/docs/auth/saml/link-vault-group-to-ad
[cross-ns]: https://developer.hashicorp.com/vault/docs/enterprise/namespaces/configure-cross-namespace-access
[namespace-api]: https://developer.hashicorp.com/vault/docs/enterprise/namespaces#vault-api-and-namespaces
