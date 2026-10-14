# Lab 106: From client count to usage-based billing metrics in Vault 2.x

This lab shows how to check the two Vault Enterprise licensing models side by side:

- **Client count (current model).** Vault bills on unique clients per month: entity clients plus
  non-entity clients. Data comes from `sys/internal/counters` and the **Client count** page in the UI.
- **Usage-based / consumption billing (Vault 2.x).** Vault bills on what each secrets engine
  manages or produces: secrets, keys, credential units, and data protection calls. Data comes from
  `sys/billing/overview` and the **Billing metrics** page in the UI.

**Executed 2026-10-14** against the existing `vault-local` container (Vault **2.1.1+ent**, raft,
TLS on `127.0.0.1:8200`). Its license includes the `Consumption Billing` feature. The numbers in
steps 10 to 11 are the measured results.

```text
                       Same activity in Vault
                                 |
            +--------------------+--------------------+
            |                                         |
   Client license (today)                 Consumption license (2.x)
            |                                         |
 sys/internal/counters/activity               sys/billing/overview
 UI: Monitoring > Client count           UI: Monitoring > Billing metrics
            |                                         |
  entity + non-entity clients     secrets | keys | credential units | data protection calls
```

> **About the term "RSU".** HashiCorp's public docs do not use "RSU". They call the new model
> *usage-based licensing* or *consumption billing* and describe four raw metric families (below).
> Vault reports those raw metrics. Any conversion into a commercial unit such as an RSU is set by
> your contract, not by a Vault API. Ask your account team for the conversion table, then apply it
> to the numbers you collect in this lab.

## How Vault decides which model you see

The model is set by the **license**, not just by the Vault version:

| Condition | What you get |
| --- | --- |
| Vault < 2.0 | Client count only (`sys/billing/certificates` exists from 1.21 for PKI-only licenses). |
| Vault ≥ 2.0.0 | The `sys/billing/overview` and `sys/billing/config` APIs exist. |
| Vault ≥ 2.0.1 | The UI dashboard for `sys/billing/overview`, plus the `start_month`/`end_month` parameters and 37-month retention. |
| License includes the feature `Consumption Billing` (for example the IBM *platform-standard* edition) | The UI hides **Client count** and shows **Billing metrics** under **Monitoring**. |
| License includes `PKI-only Secrets` | PKI-only mode: the UI hides **Client count** and billing is based on `sys/billing/certificates`. |

In the Vault UI source, the Client count page needs `!hasPKIOnly && !hasConsumptionBilling`, and
the Billing metrics page needs `hasConsumptionBilling` plus the root (or HCP `admin`) namespace.
The UI reads these features from `sys/license/features`.

The UI switch only affects what you see. In this run, on a consumption-billing license, Vault
**still counted clients**: `sys/internal/counters/activity/monthly` returned the 2 lab clients
broken down by namespace. Both the PKI-only and client counters stay active, so you can compare
the old and new models on the same cluster.

## The four usage-based metric families

| Family | How it is counted | Engines (examples) |
| --- | --- | --- |
| **Secrets** | The month's high-water mark of static secrets, auto-rotated (static) roles, and dynamic roles. Vault samples every 10 minutes. | KV, database, AWS, Azure, GCP, LDAP, Kubernetes, local accounts |
| **Keys** | The month's high-water mark of managed keys | TOTP, Key Management (KMSE) |
| **Credential units** | Duration-adjusted issuance: `TTL hours ÷ 730`, rounded to 4 decimals, minimum `0.0001` per credential | PKI, PKI External CA, SSH, identity OIDC tokens, SPIFFE |
| **Data protection operations** | One count per data element processed. Batch items count individually. Management calls are excluded. | Transit, Transform, GCP KMS |

Two more items are reported: the number of **external (non-official) plugins** in use and whether
**KMIP** was enabled during the month. All counters reset at 00:00 UTC on the first day of the month.

## Requirements

- Complete the Docker setup in [`00-docker`](../00-docker/). Keep the Compose environment in the
  repository's `vault/` directory.
- Vault Enterprise **2.0.1 or later** (`hashicorp/vault-enterprise` image). This run used
  2.1.1+ent.
- Vault CLI, `curl`, and `jq`.
- Optional: a license that includes `Consumption Billing` to see the **Billing metrics** page.

> **Warning:** the usage in this lab counts toward the **current month** on that cluster. High-water
> marks and credential units cannot be reset, and deleting the namespace does not remove them. Run
> this lab only on a lab/dev license, or set `reporting { license { development_cluster = true } }`
> in the server config. Only do that if your license agreement allows it.

All commands start from the repository root and use the explicit `-namespace` flag. Usage is
generated inside `lab-106/`. Billing endpoints are read from the root namespace because they are
restricted to it.

## 1. Start the existing Docker Vault

```bash
# Enter the directory containing your persistent Vault Compose environment.
cd vault

# Start the container (no-op if it is already running). Run `docker compose pull` first only if
# the image is older than 2.0.1.
docker compose up -d

# Configure the local CLI for this TLS-enabled Vault server.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="$PWD/certs/vault.crt"

# Wait until the Vault API responds, even if Vault is still sealed.
until curl --silent --fail --cacert "$VAULT_CACERT" \
  "$VAULT_ADDR/v1/sys/health?standbyok=true&sealedcode=200" >/dev/null; do sleep 1; done

vault status
```

If `Sealed` is `true`:

```bash
vault operator unseal "$(grep 'Unseal Key 1:' certs/init.txt | cut -d' ' -f4)"
vault operator unseal "$(grep 'Unseal Key 2:' certs/init.txt | cut -d' ' -f4)"
vault operator unseal "$(grep 'Unseal Key 3:' certs/init.txt | cut -d' ' -f4)"
```

Load the root token:

```bash
export ROOT_TOKEN="$(grep 'Initial Root Token:' certs/init.txt | cut -d' ' -f4)"
export VAULT_TOKEN="$ROOT_TOKEN"
vault token lookup >/dev/null && echo "token OK"
```

## 2. Identify the licensing model of this cluster

```bash
# Server version. You need 2.0.1+ for this lab.
vault version-history
vault status -format=json | jq -r '.version'

# License features. Look for "Consumption Billing" or "PKI-only Secrets".
vault read -format=json sys/license/status \
  | jq '.data.autoloaded // .data.persisted_autoload
        | {edition, add_ons, expiration_time,
           consumption_billing: (.features | index("Consumption Billing") != null),
           pki_only:            (.features | index("PKI-only Secrets")   != null),
           features}'

# Same check, but this is the endpoint the UI reads.
vault read -format=json sys/license/features \
  | jq -c '.data.features | map(select(test("Consumption|PKI-only")))'
```

Read the result:

- `consumption_billing: false` and `pki_only: false`: **client-count license**. This is today's model.
- `consumption_billing: true`: **usage-based license**. The UI shows *Billing metrics*.
- `pki_only: true`: **PKI-only license**. Billing is based on `sys/billing/certificates`.

Result in this run: `2.1.1+ent`, `edition: ""` (HashiCorp license, not IBM),
`consumption_billing: true`, `pki_only: false`. `sys/license/features` returned
`["Consumption Billing"]`.

Check which billing APIs answer on this cluster:

```bash
# Client model. Present on every Enterprise version.
vault read sys/internal/counters/config

# Usage model. Present from 2.0.0. Retention defaults to 37 months.
vault read sys/billing/config

# PKI model. Present from 1.21.
vault read sys/billing/certificates
```

Result in this run: all three answered. The client counter showed `enabled default-enabled` and
`retention_months 48`. Billing showed `retention_months 37`. For a month where no certificate has
been persisted yet, certificates returned
`error: certificate counts not found for 2026-10` with `issued_certificates: 0`. This is normal,
not a failure.

## 3. Take a BEFORE snapshot of both models

Define two read-only helpers for the current UTC month, so the before and after numbers are easy
to compare:

```bash
export MONTH="$(date -u +%Y-%m)"

# Client model: current month totals.
clients_now() {
  vault read -format=json sys/internal/counters/activity/monthly \
    | jq '.data | {clients, entity_clients, non_entity_clients}'
}

# Usage model: current month metrics, recalculated now (refresh_data only works on the active node).
billing_now() {
  vault read -format=json sys/billing/overview \
    refresh_data=true start_month="$MONTH" end_month="$MONTH" \
    | jq '.data.months[0] | {month, updated_at,
          metrics: [.usage_metrics[] | {(.metric_name): .metric_data}] | add}'
}

clients_now | tee before-clients.json
billing_now | tee before-billing.json
vault read -format=json sys/billing/certificates | jq '.data' | tee before-certs.json
```

> `refresh_data=true` recalculates every metric and costs server resources. Use it only in labs.
> Without it, Vault returns the value stored by the 10-minute worker (`updated_at`).

Baseline in this run: `clients: 0` for the month. In `billing/overview`, every metric was 0 except
`static_secrets.kv = 3`, which came from KV secrets left by earlier labs. Each engine reports all of
its types, so expect many `count: 0` entries. Compare the deltas, not the absolute values.

## 4. Create a clean lab namespace

```bash
vault namespace delete lab-106
until ! vault namespace list 2>/dev/null | grep -q 'lab-106/'; do sleep 1; done
vault namespace create lab-106
```

On the first run, the delete prints the warning `Matching namespace ... does not match target path
"lab-106/"; nothing to do`. This is expected.

## 5. Generate client-count activity

One user who logs in twice is **one** entity client. One token without an entity is **one**
non-entity client when it is used.

```bash
# Policy that lets a token read the lab KV mount and request an OIDC token (used in step 9).
vault policy write -namespace=lab-106 lab-reader - <<'EOF'
path "secret/data/*"               { capabilities = ["read"] }
path "identity/oidc/token/lab-role" { capabilities = ["read"] }
EOF

vault secrets enable -namespace=lab-106 -path=secret kv-v2

vault auth enable -namespace=lab-106 userpass
vault write -namespace=lab-106 auth/userpass/users/alice \
  password="alice-password" token_policies="lab-reader"

# Alice logs in twice. Expect 1 entity client, not 2.
ALICE_TOKEN=$(vault login -namespace=lab-106 -token-only -method=userpass \
  username=alice password=alice-password)
vault login -namespace=lab-106 -token-only -method=userpass \
  username=alice password=alice-password >/dev/null

# A non-entity token, created by root and then used once.
APP_TOKEN=$(vault token create -namespace=lab-106 -policy=lab-reader \
  -orphan -field=token)
VAULT_TOKEN="$APP_TOKEN" vault token lookup -namespace=lab-106 >/dev/null
```

The root token itself is never counted as a client.

## 6. Secrets: KV static secrets and the high-water mark

```bash
for i in 1 2 3 4 5; do
  vault kv put -namespace=lab-106 -mount=secret "app/config-$i" value="v$i"
done
```

Expected: `static_secrets` goes up by **+5** (`type: kv`). Step 11 shows the high-water mark
behavior.

## 7. Keys: a TOTP key

```bash
vault secrets enable -namespace=lab-106 totp
vault write -namespace=lab-106 totp/keys/lab-key \
  generate=true issuer="Vault" account_name="alice@lab" >/dev/null
```

Expected: `managed_keys` goes up by **+1** (`type: totp`).

## 8. Data protection: Transit, single and batch

```bash
vault secrets enable -namespace=lab-106 transit
vault write -namespace=lab-106 -f transit/keys/app-key   # management call, not counted

# 3 single encrypt calls = 3 operations.
for i in 1 2 3; do
  vault write -namespace=lab-106 transit/encrypt/app-key \
    plaintext="$(printf 'secret-%s' "$i" | base64)" >/dev/null
done

# 1 batch call with 4 items = 4 operations.
vault write -namespace=lab-106 transit/encrypt/app-key - >/dev/null <<EOF
{"batch_input": [
  {"plaintext": "$(printf a | base64)"},
  {"plaintext": "$(printf b | base64)"},
  {"plaintext": "$(printf c | base64)"},
  {"plaintext": "$(printf d | base64)"}
]}
EOF
```

Expected: `data_protection_calls` goes up by **+7** (`type: transit`): 3 single calls plus 4 batch
items. Creating the key is not counted.

## 9. Credential units: PKI certificates and an OIDC token

Every TTL is chosen so the expected units are easy to calculate (`TTL hours ÷ 730`).

```bash
vault secrets enable -namespace=lab-106 pki
vault secrets tune -namespace=lab-106 -max-lease-ttl=1460h pki

# Root CA, TTL 1460h: 2.0000 units. CA certificates count too.
# The root must live LONGER than the leaves. With a 730h root, a 730h leaf fails with
# "TTL would result in notAfter ... beyond the expiration of the CA certificate".
vault write -namespace=lab-106 -field=certificate pki/root/generate/internal \
  common_name="lab-106 Root" ttl=1460h >/dev/null

vault write -namespace=lab-106 pki/roles/web \
  allow_any_name=true max_ttl=730h >/dev/null

# Web server cert, TTL 730h: 1.0000 unit.
vault write -namespace=lab-106 pki/issue/web common_name="web.lab.local" ttl=730h >/dev/null

# Short-lived agent cert, TTL 5m: 0.0001 unit (the minimum).
vault write -namespace=lab-106 pki/issue/web common_name="agent.lab.local" ttl=5m >/dev/null
```

Identity OIDC token issued to Alice, TTL 1h (`1 ÷ 730 = 0.0014`):

```bash
vault write -namespace=lab-106 identity/oidc/key/lab-key allowed_client_ids="*"
vault write -namespace=lab-106 identity/oidc/role/lab-role key=lab-key ttl=1h

VAULT_TOKEN="$ALICE_TOKEN" vault read -namespace=lab-106 -field=token \
  identity/oidc/token/lab-role >/dev/null
```

Expected: `pki_units` goes up by **+3.0001** (2 + 1 + 0.0001), and `id_token_units` goes up by
**+0.0014** (`type: oidc`). The UI adds these into **Credential units**:
`ssh_units + pki_units + id_token_units`.

> **Measured gotcha:** PKI units and `sys/billing/certificates` are persisted asynchronously,
> about every 2 minutes. Right after issuance, `pki_units` was still `0` and certificates showed
> "not found", even with `refresh_data=true`. Two minutes later both were correct. OIDC units,
> Transit, KV, and TOTP showed up immediately.

## 10. AFTER snapshot: compare both models

```bash
export VAULT_TOKEN="$ROOT_TOKEN"

clients_now | tee after-clients.json
billing_now | tee after-billing.json
vault read -format=json sys/billing/certificates | jq '.data' | tee after-certs.json

# Side-by-side diff of the usage metrics.
diff <(jq -S .metrics before-billing.json) <(jq -S .metrics after-billing.json)
```

The certificate and PKI-unit counters lag by about 2 minutes (see step 9). If a number has not
moved yet, wait and run the helper again.

Results (measured on 2026-10-14, as deltas against the step 3 baseline):

| Activity | Client model (`activity/monthly`) | Usage model (`billing/overview`) | Measured |
| --- | --- | --- | --- |
| Alice logs in twice | `entity_clients` +1 | — | ✅ 1 |
| Non-entity token used once | `non_entity_clients` +1 | — | ✅ 1 |
| 5 KV secrets | — | `static_secrets.kv` +5 | ✅ 3 → 8 |
| 1 TOTP key | — | `managed_keys.totp` +1 | ✅ 1 |
| 3 + 4 batch Transit encrypts | — | `data_protection_calls.transit` +7 | ✅ 7 (the key creation is not counted) |
| Root (1460h) + 730h cert + 5m cert | — | `pki_units` +3.0001 | ✅ see note |
| OIDC token, 1h | — | `id_token_units.oidc` +0.0014 | ✅ 0.0014 |
| **Total** | **clients 2** | **secrets 5 · keys 1 · credential units 3.0015 · data protection 7** | |

`activity/monthly` also attributes the 2 clients to `lab-106/` in `by_namespace`.

> **Note on PKI in this run:** the first attempt used a 730h root, so the 730h leaf failed. A
> second 1460h root was then generated, so the measured total was **4.0001** units: 1 + 2 + 1 +
> 0.0001. `sys/billing/certificates` showed **4** certificates. This proves that **every CA
> certificate is counted in both models, by duration**, and that a failed issuance does not count.
> With the corrected step 9 you get 3.0001 units and 3 certificates.

The point of this lab: the same workload is **2 clients** under the old model. Under the new model
it is a usage vector on four axes, and it grows with what Vault manages and issues, not with how
many identities use it.

## 11. Prove the high-water mark behavior

```bash
# Delete 3 of the 5 secrets. Current count = 2.
for i in 1 2 3; do
  vault kv metadata delete -namespace=lab-106 -mount=secret "app/config-$i"
done
billing_now | jq '.metrics.static_secrets'      # still +5 vs baseline

# Add 4 new secrets. Current count = 6, higher than the previous peak of 5.
for i in 6 7 8 9; do
  vault kv put -namespace=lab-106 -mount=secret "app/config-$i" value="v$i"
done
billing_now | jq '.metrics.static_secrets'      # now +6 vs baseline
```

Measured: baseline 3 → **8** after step 6 → still **8** after deleting 3 → **9** after adding 4
(current count 3 + 6 = 9, a new peak).

Use `kv metadata delete`. A soft `kv delete` keeps the secret's metadata, so the secret may still
be counted. Deleting secrets during the month never lowers that month's number. Only a new peak
raises it.

## 12. Look at it in the UI

Open [https://127.0.0.1:8200](https://127.0.0.1:8200) and log in with the root token in the
**root** namespace.

- **Client-count license:** **Monitoring → Client count**. You see *Running client total*,
  *Entity clients*, and *Non-entity clients*, with a per-namespace and per-mount breakdown. Filter by
  `lab-106/` to see the 2 clients from step 5.
- **Consumption-billing license (2.0.1+):** **Monitoring → Billing metrics** (route
  `/ui/vault/billing/overview`). *Client count* is no longer in the menu. The page shows:
  - a month selector covering the retention period, refreshed every 10 minutes (`updated_at`);
  - a **Summary** card;
  - **Details by metric** cards: *Secrets* (static, dynamic, auto-rotated), *Credential units*
    (PKI, SSH, OIDC/SPIFFE), *Data protection calls* (Transit, Transform, GCP KMS), and
    *Managed keys* (TOTP, KMSE).
- In both cases, **Reporting → Vault usage** (`sys/utilization-report`) shows a snapshot of the
  current configuration: mounts, roles, and so on.

If you have a client license and the page `/ui/vault/billing/overview` sends you back to the
dashboard, that is expected. The UI checks for the `Consumption Billing` license feature.

In this run (with `Consumption Billing`), `sys/license/features` returned the feature that the UI
uses to show **Billing metrics** instead of **Client count**. The sidebar itself was not checked in
a browser. Client count data is still available through the API (step 10).

## 13. Optional: see both models in the license utilization payload

The payload Vault sends to IBM (automatically about every 24 h, or manually) contains client
**and** usage gauges in 2.x. Not every metric is billed: the contract decides which ones apply.

```bash
vault operator utilization -message "Lab 106" -output lab-106-utilization.json

# The bundle holds one snapshot per day (28 in this run). They are NOT sorted, so pick by timestamp.
jq '.snapshot_records | length' lab-106-utilization.json
jq '.snapshot_records | max_by(.decoded_snapshot.timestamp) | .decoded_snapshot
    | {timestamp, gauges: (.gauges
    | with_entries(select(.key | test(
        "^clientcount\\.current_month|^kv_max_count\\.current|^totp_max_count\\.current|^transit_operation_count\\.current|^normalized_certs_issued\\.current|^normalized_oidc_tokens_issued\\.current|^certcount\\.current")))
    | map_values(.value))}' lab-106-utilization.json
```

> **Measured gotcha:** the bundle does **not** contain a fresh snapshot. The newest one was taken
> when Vault was unsealed (`08:22:39`, before the lab activity). It showed `kv_max_count = 3` and 0
> for Transit, TOTP, and PKI, and `clientcount...entity = 7`, an estimate for the billing period
> rather than the month. `vault operator utilization` exports the stored daily snapshots. It does
> not take a new one. To check live numbers, use `sys/billing/overview` and
> `sys/internal/counters`. The lab's activity reaches the payload in the next daily snapshot.

Do **not** upload this file unless you report manually as part of a real agreement.

## Cleanup

```bash
export VAULT_TOKEN="$ROOT_TOKEN"

vault namespace delete lab-106
until ! vault namespace list 2>/dev/null | grep -q 'lab-106/'; do sleep 1; done

rm -f before-*.json after-*.json lab-106-utilization.json
unset -f clients_now billing_now
docker compose down
unset VAULT_ADDR VAULT_CACERT VAULT_TOKEN ROOT_TOKEN ALICE_TOKEN APP_TOKEN MONTH
```

Deleting the namespace removes the objects but **not** this month's counted usage. Credential units
and data protection calls are cumulative, and secrets and keys keep their high-water mark until the
month rolls over. Measured right after the deletion: secrets 9, keys 1, data protection 7, PKI units
4.0001, OIDC units 0.0014, clients 2. Nothing went down. Skip `docker compose down` if other labs
use the container.

## Conclusions (measured)

1. **The license decides the UI.** `Consumption Billing` in `sys/license/features` replaces
   *Client count* with *Billing metrics*. **Both counters keep running**, so you can compare the
   two models on the same cluster.
2. The same workload is **2 clients** (1 entity + 1 non-entity) in the old model. In the new model
   it is **secrets 5 · keys 1 · data protection 7 · credential units 3.0015**.
3. Batch Transit items count one by one. Key management calls do not count.
4. Credential units match `TTL hours ÷ 730` exactly, with a minimum of 0.0001. **CA certificates
   count**, and a long-lived CA can cost more than many leaves.
5. Secrets and keys are high-water marks. Deletes never lower the month's number.
6. PKI units and certificate counts lag by about 2 minutes. `refresh_data=true` does not cut the lag.
7. `vault operator utilization` exports stored daily snapshots, not live values.

## Troubleshooting

- `sys/billing/overview`: **unsupported path / 404**. The server is older than 2.0.0. Check
  `vault status`.
- `start_month`/`end_month` ignored, or no UI page: you need 2.0.1+.
- **Permission denied** on billing endpoints: they are restricted to the root namespace (`admin`
  on HCP Vault Dedicated). Do not pass `-namespace` to them.
- **Warning: `refresh_data` ignored on standby**: send the request to the active node.
- **`pki_units` = 0 or certificates "not found" right after issuing**: wait about 2 minutes. The
  counts are flushed to storage asynchronously.
- **PKI issue fails with `beyond the expiration of the CA certificate`**: the root TTL must be
  longer than the leaf TTL (see step 9).
- **Warning: months outside the retention range**: those months return a zero `updated_at` and no
  metrics. Check `vault read sys/billing/config` (13–72 months, default 37).
- **Performance replication**: each cluster reports its own usage. PR secondaries exclude replicated
  secrets and keys but count their local mounts, credential units, and data protection calls.
  Query every cluster.

## Official HashiCorp documentation

- [`/sys/billing` overview: which endpoint applies to which pricing model][billing-api]
- [`/sys/billing/overview` API][billing-overview]
- [`/sys/billing/config` API (retention)][billing-config]
- [`/sys/billing/certificates` API (PKI-only)][billing-certs]
- [Usage-based billing metrics: how secrets, keys, credential units, and operations are counted][usage-metrics]
  (restricted page on developer.hashicorp.com; the source is public on GitHub)
- [Clients and entities (client model)][clients]
- [Client usage and the Client count dashboard][client-usage]
- [`/sys/internal/counters` API][counters]
- [Certificate counting][cert-counts]
- [Vault Enterprise license keys (PKI-only mode)][license]
- [`license_entitlement` stanza (IBM editions such as platform-standard)][entitlement]
- [License utilization reporting][utilization]
- [License utilization metrics (all reported gauges)][utilization-metrics]
- [Manual license utilization reporting / `vault operator utilization`][manual-reporting]
- [Vault 2.x release notes (2.0.0 licensing framework, 2.0.1 dashboard)][release-notes]

[billing-api]: https://developer.hashicorp.com/vault/api-docs/system/billing
[billing-overview]: https://developer.hashicorp.com/vault/api-docs/system/billing/overview
[billing-config]: https://developer.hashicorp.com/vault/api-docs/system/billing/config
[billing-certs]: https://developer.hashicorp.com/vault/api-docs/system/billing/certificates
[usage-metrics]: https://github.com/hashicorp/web-unified-docs/blob/main/content/vault/v2.x/content/docs/restricted/concepts/billing/usage/metrics.mdx
[clients]: https://developer.hashicorp.com/vault/docs/concepts/billing/clients
[client-usage]: https://developer.hashicorp.com/vault/docs/concepts/billing/clients/client-usage
[counters]: https://developer.hashicorp.com/vault/api-docs/system/internal-counters
[cert-counts]: https://developer.hashicorp.com/vault/docs/concepts/billing/certificate-counts
[license]: https://developer.hashicorp.com/vault/docs/license
[entitlement]: https://developer.hashicorp.com/vault/docs/configuration/license-entitlement
[utilization]: https://developer.hashicorp.com/vault/docs/license/utilization
[utilization-metrics]: https://developer.hashicorp.com/vault/docs/license/utilization/metrics
[manual-reporting]: https://developer.hashicorp.com/vault/docs/license/utilization/manual-reporting
[release-notes]: https://developer.hashicorp.com/vault/docs/updates/release-notes
