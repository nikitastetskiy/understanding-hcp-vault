# Lab: SCEP client counting in Vault Enterprise

**Objective:** empirically verify that (1) the entity is created from the CN of the CSR,
(2) enrollment via static challenge and renewal via cert auth create **two distinct entities**
for the same device, and (3) subsequent renewals do not add new clients.

**Requirements:** Vault Enterprise ≥ 1.20 with a license, [`sscep`](https://github.com/certnanny/sscep),
`openssl`, `jq`, `socat` (only because our server is TLS-only and sscep speaks plain HTTP).

**Executed 2026-07-24** against the existing `vault-local` container (Vault **2.0.3+ent**, raft,
TLS on `127.0.0.1:8200`), reusing the SCEP setup from `102-scep-intune-configuration`:
the `pki_int` mount (SCEP-enabled) and the `scep/` auth mount.

---

## 0. Environment: unseal and client tooling

The server is persistent (not `-dev`), so unseal it with the keys from `vault/certs/init.txt`:

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=vault/certs/vault.crt
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
export VAULT_TOKEN=<root token from init.txt>
vault status    # Version 2.0.3+ent, Sealed false
```

Build `sscep` from source (no Homebrew formula):

```bash
git clone https://github.com/certnanny/sscep.git && cd sscep
autoreconf -ivf
./configure CPPFLAGS="-I/opt/homebrew/opt/openssl@3/include" LDFLAGS="-L/opt/homebrew/opt/openssl@3/lib"
make
./sscep    # sscep version 0.10.0
```

`sscep` only speaks HTTP but our listener is TLS-only, so run a TLS-terminating proxy and
point sscep at it:

```bash
socat TCP-LISTEN:8202,fork,reuseaddr,bind=127.0.0.1 OPENSSL:127.0.0.1:8200,verify=0 &
# sscep will use http://127.0.0.1:8202/v1/pki_int/scep
```

## 1. PKI engine: rotate the expired CA chain

The lab reuses `pki_int` (SCEP enabled, `default_path_policy=role:scep-clients`, RSA issuer —
**SCEP only supports RSA issuers**). But the Dadgarcorp chain from the previous lab had expired
(2026-02-01), and issuance failed with:

```
failed signing csr: cannot satisfy request, as TTL would result in notAfter ...
that is beyond the expiration of the CA certificate at 2026-02-01T10:52:37Z
```

Rotation — new root in `pki`, new intermediate in `pki_int`:

```bash
vault secrets tune -max-lease-ttl=87600h pki

# new root (RSA — mandatory for SCEP)
vault write -field=certificate pki/root/generate/internal \
    common_name="Dadgarcorp Root Authority" issuer_name="root-2026" \
    key_type=rsa key_bits=2048 ttl=87600h > root_ca.crt
vault write pki/config/issuers default="root-2026"

# new intermediate, signed by the new root
vault write -format=json pki_int/intermediate/generate/internal \
    common_name="Dadgarcorp Intermediate Authority" \
    key_type=rsa key_bits=2048 | jq -r '.data.csr' > int.csr
vault write -format=json pki/issuer/root-2026/sign-intermediate \
    csr=@int.csr ttl=43800h | jq -r '.data.certificate' > int.crt
vault write -format=json pki_int/intermediate/set-signed certificate=@int.crt
vault patch pki_int/issuer/<new-issuer-id> issuer_name="int-2026"
vault write pki_int/config/issuers default="int-2026"
```

> **Gotcha:** `pki/root/sign-intermediate` uses the mount's *default* issuer. With the old expired
> root still default, it fails with `notAfter before notBefore`. Set the default first.

The role already existed (equivalent of the original lab's role, but domain-restricted):

```bash
vault read pki_int/roles/scep-clients
# allowed_domains=[scep.dadgarcorp.com], allow_subdomains=true,
# key_type=rsa, key_bits=2048, no_store=false
```

So device CNs in this lab are `ipad-000X.scep.dadgarcorp.com`.

## 2. SCEP auth: static-challenge role (batch tokens)

The ACL policy `scep-acl-policy` (pki_int/scep paths) and the `scep/` auth mount already exist.
Add a static-challenge role next to the existing `intune` one:

```bash
vault write auth/scep/role/static-1 \
    auth_type="static-challenge" \
    challenge="MiPasswordSCEP2026" \
    token_policies="scep-acl-policy" \
    token_type="batch"
```

## 3. Cert auth for renewals (batch tokens)

Trust the **issuing** CA (the intermediate — it signs the client certs):

```bash
vault auth enable cert
vault read -field=certificate pki_int/issuer/default > issuing_ca.crt
vault write auth/cert/certs/scep-ca \
    display_name="SCEP Client CA" \
    certificate=@issuing_ca.crt \
    token_policies="scep-acl-policy" \
    token_type="batch"
```

## 4. Delegated auth + SCEP config on the PKI mount

```bash
SCEP_ACCESSOR=$(vault read -field=accessor sys/auth/scep)
CERT_ACCESSOR=$(vault read -field=accessor sys/auth/cert)

vault secrets tune \
    -delegated-auth-accessors="$SCEP_ACCESSOR" \
    -delegated-auth-accessors="$CERT_ACCESSOR" \
    pki_int

vault write pki_int/config/scep - <<EOF
{
  "enabled": true,
  "default_path_policy": "role:scep-clients",
  "external_validation": {},
  "authenticators": {
    "scep": { "accessor": "$SCEP_ACCESSOR", "scep_role": "static-1" },
    "cert": { "accessor": "$CERT_ACCESSOR", "cert_role": "scep-ca" }
  }
}
EOF
```

> **The big gotcha of this lab:** `pki_int/config/scep` still carried
> `external_validation.intune` from the Intune lab. With it present, every enrollment failed with
> `pkistatus: FAILURE / Transaction not permitted or supported`, and the audit log showed the
> delegated login being sent with `challenge_type=intune` instead of `static` — the static
> challenge was never even evaluated. **The config write does NOT clear fields you omit**: you must
> pass `"external_validation": {}` explicitly. (Re-add the Intune block to resume lab 102.)
>
> How we found it: enable a temporary audit device and compare HMACs of known strings against the
> logged request fields:
>
> ```bash
> vault audit enable -path=sceplab file file_path=/vault/logs/audit-sceplab.log
> # ...reproduce the failure, then inspect auth/scep/login entries...
> vault write -field=hash sys/audit-hash/sceplab input="intune"   # matched challenge_type!
> vault audit disable sceplab
> ```

## 5. BEFORE snapshot: entities and client count

```bash
vault list identity/entity/id
vault read -format=json sys/internal/counters/activity | jq '.data.total'
```

Result: **4 entities** (userpass/approle leftovers from earlier labs, none SCEP) and:

```json
{ "clients": 0, "entity_clients": 0, "non_entity_clients": 0 }
```

## 6. Enroll the "iPad" with static challenge

The challenge travels as the `challengePassword` attribute inside the CSR. sscep 0.10.0 doesn't
add it reliably, so embed it via an openssl config:

```bash
mkdir -p ipad-0001 && cd ipad-0001
cat > req.cnf <<'EOF'
[req]
distinguished_name = dn
attributes = req_attrs
req_extensions = ext
prompt = no
[dn]
CN = ipad-0001.scep.dadgarcorp.com
[req_attrs]
challengePassword = MiPasswordSCEP2026
[ext]
subjectAltName = DNS:ipad-0001.scep.dadgarcorp.com
EOF

openssl genrsa -out local.key 2048
openssl req -new -key local.key -out local.csr -config req.cnf
openssl req -in local.csr -noout -text | grep challengePassword   # verify it's there

sscep getca -u http://127.0.0.1:8202/v1/pki_int/scep -c ca.crt
sscep enroll -u http://127.0.0.1:8202/v1/pki_int/scep \
    -k local.key -r local.csr -l cert-v1.crt -c ca.crt -e ca.crt \
    -S sha256 -E aes256
# pkistatus: SUCCESS

openssl x509 -in cert-v1.crt -noout -subject -issuer -dates
# subject=CN=ipad-0001.scep.dadgarcorp.com
# issuer=CN=Dadgarcorp Intermediate Authority
```

> **Gotcha:** `-S sha256 -E aes256` is mandatory. The mount only allows SHA-256/384/512 and AES;
> sscep's legacy defaults are rejected with `Transaction not permitted or supported`.

**Verification (hypothesis: 1 new entity, alias on the `scep` mount):**

```bash
vault list -format=json identity/entity/id | jq -r '.[]' | while read id; do
  vault read -format=json identity/entity/id/$id \
    | jq '{name:.data.name, aliases:[.data.aliases[] | {name, mount_type, mount_accessor}]}'
done
```

Result — **CONFIRMED**. 5 entities total; the new one:

```json
{"name":"entity_6a831533",
 "aliases":[{"name":"ipad-0001.scep.dadgarcorp.com","mount_type":"scep"}]}
```

The alias name **is the CN of the CSR**. Activity now shows `clients: 1` — and it lands in
**`entity_clients`**, not `non_entity_clients`, despite the batch token:

```json
{ "clients": 1, "entity_clients": 1, "non_entity_clients": 0 }   // under auth/scep/
```

## 7. Renewal via cert auth (RenewalReq)

New key + CSR **without** challenge, signed with the old cert/key (`-K`/`-O`):

```bash
openssl genrsa -out local-v2.key 2048
openssl req -new -key local-v2.key -out renew.csr \
    -subj "/CN=ipad-0001.scep.dadgarcorp.com" \
    -addext "subjectAltName=DNS:ipad-0001.scep.dadgarcorp.com"

sscep enroll -u http://127.0.0.1:8202/v1/pki_int/scep \
    -k local-v2.key -r renew.csr -l cert-v2.crt -c ca.crt -e ca.crt \
    -K local.key -O cert-v1.crt \
    -S sha256 -E aes256
# pkistatus: SUCCESS
```

**Verification (hypothesis: 2nd entity, same CN, alias on the `cert` mount) — CONFIRMED:**

```json
{"name":"entity_6a831533","aliases":[{"name":"ipad-0001.scep.dadgarcorp.com","mount_type":"scep"}]}
{"name":"entity_ea902da8","aliases":[{"name":"ipad-0001.scep.dadgarcorp.com","mount_type":"cert"}]}
```

6 entities total, and activity:

```json
{ "clients": 2, "entity_clients": 2, "non_entity_clients": 0 }
// by mount: auth/scep/ = 1, auth/cert/ = 1
```

**One physical device = two billed clients** once it renews through cert auth.

## 8. Second renewal (hypothesis: does NOT add) — CONFIRMED

```bash
openssl genrsa -out local-v3.key 2048
openssl req -new -key local-v3.key -out renew2.csr \
    -subj "/CN=ipad-0001.scep.dadgarcorp.com" \
    -addext "subjectAltName=DNS:ipad-0001.scep.dadgarcorp.com"
sscep enroll -u http://127.0.0.1:8202/v1/pki_int/scep \
    -k local-v3.key -r renew2.csr -l cert-v3.crt -c ca.crt -e ca.crt \
    -K local-v2.key -O cert-v2.crt -S sha256 -E aes256
# pkistatus: SUCCESS
```

Entities: still 6. Clients: still 2. The alias on the cert mount already exists and resolves to
the same entity.

## 9. Optional extras

**a) Certificate count** (`sys/billing/certificates` works on this version):

```bash
vault read sys/billing/certificates
# months=[map[counts:map[issued_certificates:8] timestamp:2026-07]]
```

8 = 6 device leaves (4× ipad-0001, 2× ipad-0002) **+ the new root and intermediate** from step 1.
Every issuance counts, CA certs included, no per-device dedup — vs. 3 billed clients. The counter
updates asynchronously (lags a few seconds behind issuance).

**b) Anti-double-count with pre-created aliases** — create ONE entity with both aliases BEFORE
the first enrollment:

```bash
ENTITY_ID=$(vault write -field=id identity/entity name="ipad-0002")
vault write identity/entity-alias name="ipad-0002.scep.dadgarcorp.com" \
    canonical_id=$ENTITY_ID mount_accessor=$SCEP_ACCESSOR
vault write identity/entity-alias name="ipad-0002.scep.dadgarcorp.com" \
    canonical_id=$ENTITY_ID mount_accessor=$CERT_ACCESSOR
# then repeat steps 6-7 with CN ipad-0002.scep.dadgarcorp.com
```

Result — **it works**: entities went 6 → 7 (only the pre-created one; both logins resolved to it),
clients went 2 → 3, i.e. **ipad-0002 = 1 client** across enroll + renew:

```json
{"name":"ipad-0002","aliases":[
  {"name":"ipad-0002.scep.dadgarcorp.com","mount_type":"scep"},
  {"name":"ipad-0002.scep.dadgarcorp.com","mount_type":"cert"}]}
```

Per-mount attribution counts it under the mount where it was first seen that month (`auth/scep/`).

**c) Same CN, second challenge enrollment from "another machine"** (new key, step 6 again):
`pkistatus: SUCCESS`, entities still 7, clients still 3 — **the scep-mount alias is reused**
(alias lookup is by name + mount accessor; the key doesn't matter).

---

## Results table

| Step | Action | Total entities | Clients (activity) | Certs (billing) |
|---|---|---|---|---|
| 5 | baseline | 4 | 0 | 0 |
| 6 | enroll via static challenge | 5 (+1, alias on `scep`) | 1 (entity_clients) | 1 leaf |
| 7 | renew via cert auth | **6 (+1, alias on `cert`)** | **2** | 2 leaves |
| 8 | 2nd renewal | 6 | 2 | 3 leaves |
| 9b | ipad-0002 with pre-created dual-alias entity | 7 | **3 (+1 only)** | 5 leaves |
| 9c | same CN, new key, challenge again | 7 | 3 | 6 leaves |

## Conclusions

1. **Confirmed** — the entity alias is created from the CSR CN; auto-named entity, alias on the
   `scep` auth mount.
2. **Confirmed** — cert-auth renewal creates a **second entity** (same alias *name*, different
   mount accessor). Same device → 2 entities → 2 clients.
3. **Confirmed** — later renewals reuse the cert-mount alias: no new entity, no new client.
4. **The detail the docs don't spell out:** batch tokens notwithstanding, SCEP and cert logins
   count as **`entity_clients`** — entity aliases are created for them regardless of token type.
5. **Mitigation that works:** pre-creating one entity holding both aliases (scep + cert accessor)
   before first contact collapses the device to 1 client.
6. **Certificate billing** counts every issuance (leaves and CA certs) with no dedup.

## Troubleshooting notes

- `Transaction not permitted or supported` right after `sending certificate request` → check
  (a) `-S sha256 -E aes256` flags, and (b) leftover `external_validation` in `pki_int/config/scep`
  (see step 4 — audit device + `sys/audit-hash` is the way to see what the PKI mount actually
  forwards to `auth/scep/login`).
- `notAfter before notBefore` when signing the intermediate → the mount's default issuer is still
  the expired one.
- Issuance failing with `beyond the expiration of the CA certificate` → the chain is expired;
  rotate (step 1).
- If step 7 fails auth, verify `auth/cert/certs/scep-ca` holds the **current intermediate** (it
  must be updated after a CA rotation) and that cert-v1 hasn't expired (leaf TTL here is short —
  the mount default, ~73 min).
- `vault secrets list`/`identity` reads returning empty on a fresh unseal: give the raft node a few
  seconds to elect itself active.
