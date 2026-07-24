# Lab results: SCEP client counting in Vault Enterprise

Executed 2026-07-24 against the existing `vault-local` container (Vault **2.0.3+ent**, raft storage),
reusing the `pki_int` SCEP setup from the Intune lab (`102-scep-intune-configuration`).

**Goal:** empirically verify that (1) the entity is created from the CSR CN, (2) enrollment via
static challenge and renewal via cert auth create **two distinct entities** for the same device,
and (3) subsequent renewals do not add new clients.

## Environment deltas vs. the original lab script

The lab was run on the existing server instead of a fresh `-dev` one, so a few adaptations were needed:

| Original lab | What was actually used |
|---|---|
| `vault server -dev` | Existing `vault-local` container (unsealed with keys from `vault/certs/init.txt`) |
| Mount `pki` + new root | Existing `pki_int` (SCEP already enabled, `default_path_policy=role:scep-clients`) |
| `allow_any_name=true`, CN `*.empresa.com` | Existing role `scep-clients` allows `*.scep.dadgarcorp.com`, so CNs are `ipad-000X.scep.dadgarcorp.com` |
| New `scep` auth mount | Existing `scep/` mount + **new role** `static-1` (static-challenge, batch, policy `scep-acl-policy`) |
| New `cert` auth mount | Enabled `cert/`, role `certs/scep-ca` trusting the **intermediate** CA, batch tokens |
| `http://127.0.0.1:8200` | Server is TLS-only and `sscep` is HTTP-only → `socat TCP-LISTEN:8202,fork,reuseaddr,bind=127.0.0.1 OPENSSL:127.0.0.1:8200,verify=0` and enroll against `http://127.0.0.1:8202/v1/pki_int/scep` |

`sscep` 0.10.0 was built from source (github.com/certnanny/sscep, `autoreconf -ivf && ./configure && make`).

## Problems hit on the way (worth knowing)

1. **Leftover Intune `external_validation` hijacks the challenge.** `pki_int/config/scep` still carried
   `external_validation.intune` from the 102 lab. With it present, the delegated login was sent with
   `challenge_type=intune` and failed with `permission denied` even though the static-challenge role was
   configured. Writing the config with an explicit `"external_validation": {}` fixed it — the config
   write does **not** clear fields you omit.
2. **Expired CA chain.** The Dadgarcorp root/intermediate had expired 2026-02-01. Issuance failed with
   `TTL would result in notAfter ... beyond the expiration of the CA certificate`. Fixed by generating a
   new root in `pki` (issuer `root-2026`, RSA 2048, 10y), signing a new intermediate for `pki_int`
   (issuer `int-2026`, 5y), setting both as default issuers, and re-pointing `auth/cert/certs/scep-ca`
   at the new intermediate.
3. **sscep algorithm defaults.** The mount only allows SHA-256/384/512 and AES, so `sscep enroll` needs
   `-S sha256 -E aes256` (its legacy defaults are rejected with `Transaction not permitted or supported`).
4. **`challengePassword` in the CSR.** Embedded via an openssl config `attributes` section rather than
   relying on sscep flags — verify with `openssl req -in local.csr -noout -text`.
5. **Debugging tip.** A temporary file audit device plus `sys/audit-hash` lets you decode which values
   the PKI mount forwards to `auth/scep/login` (that's how the `challenge_type=intune` issue was found).

## Results table

Baseline: 4 pre-existing entities (userpass/approle from earlier labs), 0 clients in the July billing
period, 0 issued certificates.

| Step | Action | Total entities | Clients (activity) | Certs (billing) |
|---|---|---|---|---|
| 5 | baseline | 4 | 0 | 0 |
| 6 | enroll ipad-0001 via static challenge | **5** (+1: alias `ipad-0001.scep.dadgarcorp.com` on `scep` mount) | **1** (`entity_clients=1`) | 1 leaf (+2 CA certs from rotation) |
| 7 | renew via cert auth (new key, RenewalReq signed with v1 cert) | **6** (+1: second entity, same alias name, on `cert` mount) | **2** (1 on `auth/scep/`, 1 on `auth/cert/`) | 2 leaves |
| 8 | 2nd renewal (v3, signed with v2) | 6 (no change) | 2 (no change) | 3 leaves |
| 9b | ipad-0002 with pre-created entity holding both aliases, enroll + renew | 7 (only the pre-created one) | **3** (ipad-0002 = 1 client total) | 5 leaves |
| 9c | ipad-0001 re-enroll via challenge, new key ("another machine") | 7 (no change — alias reused) | 3 (no change) | 6 leaves |

Final `sys/billing/certificates` for 2026-07: **8 issued certificates** = 6 device leaves
(4× ipad-0001, 2× ipad-0002) + new root + new intermediate. No deduplication per device — compare
with 3 billed clients.

## Conclusions (hypotheses vs. reality)

1. **Confirmed** — the entity alias is created from the CSR CN (`ipad-0001.scep.dadgarcorp.com`), with
   an auto-named entity (`entity_6a831533`) and the alias on the `scep` auth mount.
2. **Confirmed** — the cert-auth renewal created a **second** entity with the *same alias name* but on
   the `cert` mount accessor. Same physical device → 2 entities → **2 billed clients**.
3. **Confirmed** — further renewals resolve to the existing `cert`-mount alias: no new entity, no new
   client.
4. **Surprise (positive):** despite batch tokens, SCEP/cert logins were counted as **`entity_clients`**,
   not `non_entity_clients` — because entity aliases are created for them, batch token or not.
5. **Anti-double-count pattern works:** pre-creating one entity with both aliases (scep accessor +
   cert accessor) *before* first enrollment makes the device count as **1 client** across enroll+renew.
   Per-mount attribution shows the client under the mount where it was first seen that month.
6. **Certificate counting** (`sys/billing/certificates`) counts every issuance — leaves *and* CA certs —
   with no per-device dedup, and the counter updates asynchronously (lags by a few seconds).

## State left on the server

- New issuers: `root-2026` (default in `pki`), `int-2026` (default in `pki_int`) — the old expired
  Dadgarcorp issuers are still present but no longer default.
- `auth/scep/role/static-1` (challenge `MiPasswordSCEP2026`), `cert/` auth mount with `certs/scep-ca`.
- `pki_int` tuned with `delegated_auth_accessors` for both mounts; `pki_int/config/scep` authenticators
  set to `{scep: static-1, cert: scep-ca}` and **`external_validation` cleared** — re-add the Intune
  block if you want to continue the 102 lab.
- Entities: 2× ipad-0001 (scep + cert), 1× ipad-0002 (both aliases), plus prior lab entities.
- Diagnostic audit device removed; socat proxy stopped (restart with the command above to re-run).
