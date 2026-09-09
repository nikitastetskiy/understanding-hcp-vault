# Vault audit logging and observability with Elastic

## Recommendation

The HashiCorp [Audit Vault with Elasticsearch for incident response][hashicorp-tutorial]
tutorial is a valid demonstration of the Elastic integration. Its data path is:

```text
Vault socket audit device
  -> TCP connection to Elastic Agent port 9007
  -> Hashicorp Vault integration ingest pipeline
  -> Elasticsearch data stream
  -> Kibana dashboard and Discover

Vault file audit device
  -> /vault/logs/vault-audit.json
  -> local jq searches in the tutorial
```

The socket audit device does **not** write an upstream file first. Vault serializes each audit
record and writes it directly to the TCP socket. The tutorial's file is produced independently by
its second audit device. In the tutorial, Elastic ingests the socket stream while the file remains
available for local investigation.

That design is good for learning and demonstrates two audit devices, but it is not the default
production design I would recommend. Elastic currently recommends its **file input** for
production because persisting to disk before collection gives stronger delivery guarantees.
HashiCorp also warns that remote TCP sockets can lose an entry on a connection interruption and
recommends a local Unix socket when a socket device is required.

A practical production default is:

```text
Vault node
  -> file audit device on a dedicated local volume
  -> node-local Elastic Agent tails the file
  -> Elasticsearch

  -> second audit device of a different type
  -> independent local/remote destination
```

Use TCP directly to Elastic Agent only after evaluating its failure behavior and network
reliability under production-like load. Do not point Vault straight at the Elasticsearch HTTP API;
Vault's socket device emits newline-delimited audit JSON, not Elasticsearch bulk API requests.

## Do you need two audit devices?

Yes, for production HashiCorp recommends at least two audit devices of different types, with at
least one forwarding to a remote system for analysis and long-term storage.

This is an availability and completeness decision, not just duplication for convenience:

- Vault writes every request and response to every enabled audit device.
- Vault guarantees that each entry reaches at least one enabled device.
- If no device can accept an entry, Vault refuses the corresponding API request.
- One failed device can therefore be tolerated when another device still works.
- Because the successful destination can differ per entry, a complete investigation must search
  the combined records from all devices.

Two devices do not automatically mean that Elastic should ingest both copies into the same data
stream. Doing that creates duplicates. If both are centralized, preserve source metadata and
deduplicate matching copies using the Vault request ID plus the record `type` (`request` or
`response`). A simpler arrangement is one production file feed into Elastic plus an independent
second destination retained for recovery and completeness checks.

The lab deliberately follows the tutorial's combination:

| Device or source | Destination | Purpose |
|---|---|---|
| `elastic-socket/` socket audit device | Elastic Agent TCP `9007` | Searchable audit data in Elastic |
| `local-file/` file audit device | `/vault/logs/vault-audit.json` | Independent local audit copy |
| Vault operational log | `/vault/logs/vault-operational.json` | Server process troubleshooting |

The two audit devices receive the same audit activity. The operational log is not an audit device
and does not count as the second audit destination.

## Audit logs, operational logs, and metrics

Vault exposes three complementary observability signals:

| Signal | Answers | Collection in the Elastic integration |
|---|---|---|
| Audit logs | Who called which API path, what operation was attempted, and whether it failed? | File audit JSON or TCP socket audit JSON |
| Operational logs | What is the Vault server process doing, warning about, or failing to do? | Vault stdout captured to a file, or Vault's `log_file` output |
| Metrics | Is Vault healthy, sealed, slow, overloaded, or failing audit writes? | Prometheus scrape of `/v1/sys/metrics` |

Audit logging is disabled on a new Vault cluster and must be enabled immediately after
initialization. It records almost every API request and response; a [documented set of health,
seal, initialization, and related endpoints][audit-exemptions] is exempt.

Operational logs are emitted by the Vault server process. On a systemd host they commonly go to
`journald`; in Docker they normally go to container stdout and are visible through `docker logs`.
The Elastic integration's operational-log input reads a file, so the platform must write or expose
that stdout stream as a file. This lab starts Vault with JSON formatting and `-log-file` to make
that boundary explicit. This is separate from `vault audit enable file`.

Metrics are not enabled in this focused lab, but they should be part of production monitoring.
In particular, HashiCorp recommends alerting on audit request/response failure metrics. The Elastic
integration can scrape the Prometheus endpoint with a narrowly scoped Vault token permitted to
read `sys/metrics`.

## What this lab proves

The automated lab is a smaller, current, command-line version of the official tutorial. It starts:

- Vault Community `1.20.4` in disposable dev mode.
- Elasticsearch and Kibana `8.17.3` with Basic licensing.
- Elastic Agent `8.17.3` in standalone mode.
- Hashicorp Vault Elastic integration package `1.31.0` and its ingest pipelines.

It then:

1. Enables a TCP socket and file audit device.
2. Creates a KV secret, restricted policy, userpass user, and non-root token.
3. Generates a successful secret read.
4. Generates an invalid-password event.
5. Generates a permission-denied secret read.
6. Verifies the file audit log exists and contains data.
7. Queries Elasticsearch for parsed failed-login and permission-denied events.
8. Correlates the analyst's audit activity by Vault entity and client ID.
9. Creates an `ibm...p` AppRole and verifies Elastic can correlate its role, entity, and client ID.
10. Verifies that Vault operational events were indexed separately.
11. Stops Elastic Agent and proves Vault still serves a request through the file audit device.

The Elastic package transforms raw Vault fields into both
`hashicorp_vault.audit.*` and standard Elastic Common Schema fields. Examples include:

| Raw Vault field | Elastic field |
|---|---|
| `time` | `@timestamp` |
| `request.id` | `event.id` |
| `request.operation` | `event.action` |
| `request.remote_address` | `source.ip` |
| Presence or absence of `error` | `event.outcome` |

## Prerequisites

- Docker with at least 4 GB of memory available; more is preferable.
- Vault CLI.
- `curl` and `jq`.
- Available local ports `18201`, `19007`, `19200`, and `15601`.
- Internet access for Docker images and Elastic package installation.

No Vault Enterprise license is required because audit devices used here are available in Vault
Community. The stack is intentionally insecure and disposable: Vault uses dev mode, TLS is off,
and lab passwords are fixed. Do not use this Compose configuration in production.

## Run the lab

Run all commands from this directory:

```bash
docker compose up -d
./run-lab.sh
```

The first startup downloads large Elastic images and can take several minutes. Expected output:

```text
PASS Vault: two audit devices are enabled (TCP socket and file)
PASS file: Vault appended JSON audit records to the local file device
PASS Elastic: indexed 1 failed userpass audit event(s)
PASS Elastic: indexed 2 permission-denied audit event(s)
PASS Elastic: attributed audit event(s) to entity/client <UUID>
PASS Elastic: classified 1 expected-unused-pattern AppRole event(s) for client <UUID>
PASS Elastic: indexed Vault operational log event(s)
PASS resilience: Vault served a request through the file device while TCP was down
Lab completed successfully. Kibana: http://127.0.0.1:15601
```

Vault usually writes both a request and response record for an API operation. Some failures are
known before a normal request record is emitted, so exact event counts can vary by operation and
Vault version. The script asserts meaningful minimums rather than a brittle total count.

If a previous run was interrupted, reset all disposable state:

```bash
docker compose down --volumes
docker compose up -d
./run-lab.sh
```

## Explore in Kibana

Open [http://127.0.0.1:15601](http://127.0.0.1:15601) and sign in:

```text
Username: elastic
Password: elastic-lab-password
```

Open **Discover**, select the `logs-*` data view if prompted, and use these KQL queries.

Failed login:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.request.path: "auth/userpass/login/analyst" and
event.outcome: "failure"
```

Denied secret access:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.request.path: "secret/data/not-authorized" and
event.outcome: "failure"
```

Successful read of the allowed secret:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.request.path: "secret/data/application/config" and
event.outcome: "success"
```

Operational logs only:

```text
data_stream.dataset: "hashicorp_vault.log"
```

## Audit clients and entities

Yes, Elastic can answer security questions such as "what did this Vault identity do?" and "which
client made this denied request?" The [Vault audit schema][audit-schema] and Elastic integration
expose these useful correlation fields:

| Elastic field | Meaning |
|---|---|
| `hashicorp_vault.audit.auth.entity_id` | Identity entity associated with the token |
| `hashicorp_vault.audit.request.client_id` | Vault client ID assigned to the request |
| `hashicorp_vault.audit.auth.display_name` | Human-readable token identity, such as `userpass-analyst` |
| `hashicorp_vault.audit.auth.metadata` | Auth-method metadata, such as the username |
| `hashicorp_vault.audit.auth.accessor` | Token accessor, HMAC'd unless configured otherwise |
| `hashicorp_vault.audit.request.remote_address` | Source address as observed by Vault |
| `hashicorp_vault.audit.request.id` / `event.id` | Correlates request and response records |

For entity-backed authentication, `request.client_id` is normally the entity ID. The lab proves
this for its userpass identity by obtaining the analyst's entity ID from Vault and requiring an
Elastic event where both fields equal that UUID.

Find all indexed activity for a known entity UUID:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.auth.entity_id: "<ENTITY_UUID>"
```

Find the same client through the request-level field:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.request.client_id: "<CLIENT_ID>"
```

Investigate denied activity by that identity:

```text
hashicorp_vault.audit.auth.entity_id: "<ENTITY_UUID>" and
event.outcome: "failure"
```

Find activity by a readable auth display name, then pivot to the stable entity UUID:

```text
hashicorp_vault.audit.auth.display_name: "userpass-analyst"
```

Use stable IDs as the primary correlation keys. Display names, usernames, IP addresses, and role
names can change or be shared. Proxies can also mask the original client IP unless trusted proxy
and request-header handling is configured correctly.

### Audit investigation is not client-count reporting

Do not count unique `client_id` values in Elastic and treat the result as Vault's authoritative
monthly active-client or licensing total. Audit logs are optimized for request investigation and
can be filtered, incomplete during destination failures, duplicated across devices, or outside the
exact billing window. Some client categories and non-entity-token rules also require Vault's own
counting logic.

Use Vault's activity log and client-count APIs or export for authoritative client usage reporting.
Use Elastic to investigate the behavior attached to a known `client_id` or `entity_id`, build
alerts, and correlate it with paths, outcomes, source addresses, and time. The two data sources
complement one another:

```text
Vault activity/client data -> which clients were counted in the period
Vault audit data in Elastic -> what those clients attempted and what Vault returned
```

### SITA client investigation in Elastic

For the SITA and HashiCorp review, use Vault's client activity export as the authoritative population
of counted clients and Elastic as the investigation layer. Elastic can classify the audit evidence,
show activity for roles that were expected to be unused, and expose one role being associated with
several entity/client IDs. It cannot independently reproduce Vault's billing algorithm.

The start of audit coverage is a hard boundary. In the described case, auditing began on 11 May, so
the absence of an Elastic event cannot establish that a client was inactive from 1-10 May. Record
the cluster, namespace, query window, export generation time, Vault version, audit filters, and known
ingestion outages with every result.

#### Add investigation classifications

In Kibana, create the following **runtime fields** on the `logs-*` data view. Runtime fields keep the
lab non-destructive: they classify the indexed events without changing the official integration's
ingest pipeline or reindexing data.

`vault.client_type` as `keyword`:

```painless
if (doc.containsKey('hashicorp_vault.audit.auth.entity_id') &&
    doc['hashicorp_vault.audit.auth.entity_id'].size() != 0) {
  emit('entity');
} else if (doc.containsKey('hashicorp_vault.audit.request.client_id') &&
           doc['hashicorp_vault.audit.request.client_id'].size() != 0) {
  emit('non-entity');
}
```

`vault.expected_unused_role_observed` as `boolean`:

```painless
if (doc.containsKey('hashicorp_vault.audit.auth.metadata.role_name') &&
    doc['hashicorp_vault.audit.auth.metadata.role_name'].size() != 0) {
  def role = doc['hashicorp_vault.audit.auth.metadata.role_name'].value;
  emit(role.startsWith('ibm') && role.endsWith('p'));
}
```

The second field does not declare the client invalid or non-billable. A `true` value means only that
the available audit evidence contradicts the expectation that an `ibm...p` role was unused.

The official integration maps `hashicorp_vault.audit.auth.metadata` as `flattened`. Flattened leaf
keys such as `.role_name` can be queried and aggregated as keyword-like values, but are not analyzed
as full text. Inspect one AppRole document in Discover before creating the runtime field because the
available metadata still depends on the auth method and Vault record. If a deployment uses a custom
mapping, add a narrowly scoped custom ingest pipeline rather than modifying the package-managed
pipeline.

#### Find the roles expected to be unused

Set the Kibana time picker to the evidence window, for example 11-31 May, and run:

```text
data_stream.dataset: "hashicorp_vault.audit" and
vault.expected_unused_role_observed: true
```

In a Lens table, use role name as the row and add these metrics:

- Unique count of `hashicorp_vault.audit.request.client_id`.
- Unique count of `hashicorp_vault.audit.auth.entity_id`.
- Unique count of `event.id` as an approximate operation count.
- Minimum and maximum `@timestamp`.
- Top values of `source.ip`, `event.action`, and `hashicorp_vault.audit.request.path`.

Vault normally emits request and response audit records with the same `request.id`, mapped to
`event.id`. A unique count of `event.id` avoids counting that pair twice. It is an activity metric,
not a billing quantity. If copies from multiple audit devices are indexed, use the same event ID
plus cluster identity when deduplicating or aggregating across independent clusters.

#### Detect possible entity recreation

Create another Lens table with role name as the row, **unique count** of
`hashicorp_vault.audit.auth.entity_id` as the metric, and filter for values greater than one. A role
such as `ibmmq-sf2mqiqclr-clr-q` associated with several entity IDs is evidence of identity churn
and is consistent with the reported Terraform recreation scenario.

It is not proof that Terraform caused the recreation. Confirm the cause against Terraform state and
apply logs, Vault entity/alias lifecycle records, and the client activity export. A stable AppRole or
display name is descriptive metadata; it is not necessarily the stable identity used for client
counting.

If the Terraform caller's user agent is available in the indexed audit document, add it to the table
and filter it as supporting evidence. Do not classify an entity as Terraform-created solely from a
`Go-http-client/1.1` user agent because many Go applications use that value.

#### Reconcile with the Vault export

Compare the 3 July client activity export with Elastic by stable `client_id`, keeping three result
sets:

| Result set | Interpretation |
|---|---|
| Export client with Elastic evidence | Investigate the role, paths, first/last event, IP, and outcomes |
| Export client without Elastic evidence | Unknown when audit coverage is partial; do not label unused |
| Elastic client absent from the export | Check cluster, namespace, export period, ingestion duplication, and ID source |

For a small review, use the exported IDs in a KQL filter:

```text
data_stream.dataset: "hashicorp_vault.audit" and
hashicorp_vault.audit.request.client_id: (
  "<CLIENT_ID_1>" or "<CLIENT_ID_2>" or "<CLIENT_ID_3>"
)
```

For a repeatable large-scale reconciliation, ingest a sanitized copy of the Vault export into a
separate, access-controlled Elasticsearch index and correlate by `client_id` with an ES|QL `LOOKUP
JOIN` or an Elasticsearch enrich policy. Do not put client exports into the audit data stream or
modify the package-managed mappings. This preserves provenance: the export says which clients Vault
counted, while the audit data explains what those IDs did.

The integration also installs its **[Hashicorp Vault] Audit Logs** and operational-log dashboards.
The official tutorial uses these same integration assets but configures Fleet interactively. This
lab installs the official package through Kibana and runs a standalone Elastic Agent so the entire
proof is repeatable without manual enrollment steps.

## Inspect the local audit device

The audit file is inside the shared Docker volume. Query denied events directly:

```bash
docker compose exec -T vault sh -c \
  "grep 'permission denied' /vault/logs/vault-audit.json"
```

Copy it to stdout for richer host-side `jq` queries:

```bash
docker compose exec -T vault sh -c \
  'test -f /vault/logs/vault-audit.json && cat /vault/logs/vault-audit.json' \
  | jq 'select(.request.path == "secret/data/not-authorized")'
```

The default audit format protects most string values with per-device HMAC-SHA256. Paths and some
other operationally useful attributes remain readable, while tokens, passwords, and secret values
are not logged in plaintext. To compare a known plaintext with a hashed field, use that device's
audit hash endpoint:

```bash
export VAULT_ADDR=http://127.0.0.1:18201
export VAULT_TOKEN=root
vault write sys/audit-hash/local-file input="a-known-value"
```

Each audit device has its own HMAC key, so the same plaintext produces a different hash in the
socket and file outputs. Do not disable hashing globally or use `log_raw=true` for routine
collection; raw auditing can expose secrets and should only be a tightly controlled, temporary
diagnostic measure.

## How the files are handled

There are two different files in the Docker volume:

```text
/vault/logs/vault-audit.json
/vault/logs/vault-operational.json
```

`vault-audit.json` is opened and appended by the Vault **file audit device**. Vault does not rotate
file audit devices. In production, use a dedicated volume, monitor its capacity and I/O, configure
`logrotate` or equivalent, and send Vault `SIGHUP` after rotation so it reopens the file.

`vault-operational.json` is written by Vault's **server logger** because the lab uses
`-log-file`. Vault has separate operational log rotation flags, or the host platform can manage
stdout. Neither mechanism replaces audit logging.

The Elastic Agent mounts the volume read-only for operational logs. It does not ingest
`vault-audit.json` in this lab because audit events arrive over TCP, matching the official
tutorial. To test Elastic's production-preferred file audit input instead, disable the TCP stream,
add `/var/log/vault/vault-audit.json` as a `hashicorp_vault.audit` filestream, and keep a genuinely
independent second Vault audit device.

## Production design guidance

### Prefer file collection by default

On each Vault node, use a file audit device on a dedicated local volume and run an Elastic Agent
close to the file. This persists records before forwarding, tolerates a temporary Elastic outage
better than a remote TCP stream, and matches Elastic's current performance and scaling guidance.
Size disk capacity for peak audit volume and the longest expected collector outage.

Audit device configuration replicates to Vault cluster nodes. Every node that might become active
must be able to write the configured path or reach the configured destination. Test failover and
audit destination failures, not only normal ingestion.

### Keep a second, independent device

Choose a second device with a different failure domain. Depending on the platform this can be a
file plus local Unix socket, file plus TCP syslog, or another organization-approved combination.
HashiCorp recommends local Unix sockets over remote TCP socket audit devices. Kubernetes commonly
uses a file audit device targeting `stdout`, with a prefix that lets a cluster collector separate
audit records from operational logs.

### Treat audit delivery as part of Vault availability

Audit writes are blocking by design. Monitor free disk, inode use, I/O latency, rotation, agent
health, network queues, and Vault's audit failure telemetry. Test what happens when each
destination and all destinations are unavailable. The desired result is continued service with
one failed device and refusal to process unaudited operations when all devices fail.

### Tune volume carefully

HashiCorp recommends `elide_list_responses=true` to avoid enormous LIST response records and
`hmac_accessor=false` so investigators can use a visible token accessor for revocation. Vault
Enterprise 1.16 and later also supports audit filters. Filtering can reduce cost and noise, but it
can remove evidence needed by an investigation. Document filters and exclusions and test security
queries against the resulting schema.

### Secure Elastic and retention

Use TLS and authenticated connections in production. Restrict access to audit data because hashes,
identity metadata, paths, IP addresses, and lease information remain sensitive. Apply an ILM/data
retention policy based on legal and incident-response requirements, preserve an immutable or
tamper-resistant copy where required, and alert on root token activity, audit configuration
changes, authentication failures, and permission-denied spikes.

## Tutorial verdict

The official tutorial still demonstrates the correct Vault and Elastic primitives and its incident
queries remain useful. The lab confirms the core flow works with Vault `1.20.4`, Elastic `8.17.3`,
and Hashicorp Vault integration `1.31.0`.

Use the tutorial as an **incident-response learning exercise**, not as an unmodified production
reference architecture. Its Elastic Stack `8.3.3` setup and manual Fleet workflow are old, and a
remote TCP socket is no longer Elastic's recommended production input. Keep the two-audit-device
principle, but normally make durable file collection the primary Elastic feed and select an
independent second device based on the deployment platform and failure domains.

## Cleanup

```bash
docker compose down --volumes
unset VAULT_ADDR VAULT_TOKEN ELASTIC_PASSWORD
```

## Official documentation

- [HashiCorp: Audit Vault with Elasticsearch for incident response][hashicorp-tutorial]
- [Elastic: Hashicorp Vault integration][elastic-integration]
- [HashiCorp: Audit logging overview][audit-overview]
- [HashiCorp: Audit log entry schema][audit-schema]
- [HashiCorp: Audit logging best practices][audit-best-practices]
- [HashiCorp: File audit device][file-audit]
- [HashiCorp: Socket audit device][socket-audit]
- [HashiCorp: Troubleshoot Vault logs][vault-logs]
- [HashiCorp: Vault configuration parameters][vault-config]
- [HashiCorp: Telemetry configuration][telemetry]
- [HashiCorp: Clients and entities][clients-entities]
- [HashiCorp: Client usage][client-usage]

[hashicorp-tutorial]: https://developer.hashicorp.com/vault/tutorials/operations/audit-elastic-incident-response
[elastic-integration]: https://www.elastic.co/docs/reference/integrations/hashicorp_vault
[audit-overview]: https://developer.hashicorp.com/vault/docs/audit
[audit-schema]: https://developer.hashicorp.com/vault/docs/audit/schema
[audit-best-practices]: https://developer.hashicorp.com/vault/docs/audit/best-practices
[audit-exemptions]: https://developer.hashicorp.com/vault/docs/audit#exempted-api-endpoints
[file-audit]: https://developer.hashicorp.com/vault/docs/audit/file
[socket-audit]: https://developer.hashicorp.com/vault/docs/audit/socket
[vault-logs]: https://developer.hashicorp.com/vault/tutorials/monitoring/troubleshooting-vault#vault-logs
[vault-config]: https://developer.hashicorp.com/vault/docs/configuration
[telemetry]: https://developer.hashicorp.com/vault/docs/configuration/telemetry
[clients-entities]: https://developer.hashicorp.com/vault/docs/concepts/billing/clients
[client-usage]: https://developer.hashicorp.com/vault/docs/concepts/billing/clients/client-usage
