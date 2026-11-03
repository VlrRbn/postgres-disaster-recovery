# Patroni Primary Endpoint Acceptance Evidence

- Result: PASS
- Date: `2026-11-03`
- Source: working changes on `feat/patroni-haproxy`, based on `98ca611` (`v0.13.0`)
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; Patroni: `4.1.5`; etcd: `3.6.5`; HAProxy: `3.2.26-alpine`
- Test project: `postgres-dr-patroni-test-1793707029-179070`

## Validation

`make patroni-acceptance` passed all eight stages with HAProxy added to the
disposable Patroni cluster. All 25 acknowledged workload inserts used
`haproxy:5432` with `sslmode=verify-full`.

| Check | Observed Result |
| --- | --- |
| Primary routing | SQL through HAProxy reported `pg_is_in_recovery() = f`, the elected node's address, and an encrypted PostgreSQL session |
| Published port | The SQL listener was bound only to `127.0.0.1`; a PostgreSQL SSLRequest and CA/hostname-verified TLS handshake succeeded through the assigned host port |
| Node exposure | PostgreSQL and etcd had no published host ports |
| Client TLS guards | Plaintext was rejected by HBA; untrusted certificates and a wrong server name failed verification |
| HTTPS role checks | A separate proxy with the valid CA and names routed SQL; wrong-host and untrusted-CA fixtures reported TLS failures and could not route SQL |
| Proxy credentials | HAProxy mounted no database passwords or private keys |
| Existing controls | Replica writes, REST authentication, etcd mutual TLS, node key boundaries, and password-free container environments passed |
| Single etcd loss | The majority of two preserved leader coordination and writes |
| Leader crash | An established SQL connection through HAProxy broke after SIGKILL; a fresh verified connection at the same address reached the promoted replica |
| Acknowledged loss | The deliberately isolated replica retained 20 of 25 acknowledged orders; `patroni-workload-021` through `patroni-workload-025` were absent |
| Former leader | The restarted node rejoined as a streaming replica; both databases held the same 21 surviving orders |
| Quorum loss | Both PostgreSQL nodes became stopped or read-only, neither API advertised a primary, and the proxy refused SQL connections |
| Quorum restoration | The same endpoint accepted a new write after coordination recovered; both databases contained 22 exact rows |
| Recreation | PostgreSQL and etcd state survived container recreation; the shared endpoint, direct role-aware SQL helpers, and TLS/access controls passed again |

Promotion was observed after `18.693 s`; the first successful verified SQL
connection through HAProxy was observed after `20.980 s`. Both measurements
start at leader-container kill and include reconnecting the deliberately isolated
replica. Endpoint recovery also includes starting the disposable client. These
measurements are not application recovery guarantees.

The report and all 25 acknowledgment records remain under
`.local/reports/postgres-dr-patroni-test-1793707029-179070-patroni.json`
and `.jsonl`. Cleanup removed the six services, temporary SQL clients and proxy
fixtures, five data volumes, two networks, and private temporary files.

## Regression

`make check` passed 72 Python tests, ShellCheck, shell syntax, five Compose
models, systemd declarations/calendars, and diff formatting. Certificate tests
recreated the previous node identities and verified that setup adds the shared
hostname without changing the CA, keys, or other certificates. A repeated setup
preserved every file. A signing failure for the second node left both previous
certificates intact. Existing replication TLS tests also passed.

Workflow YAML parsing confirmed that the existing `Foundation checks` job runs
the extended `make patroni-acceptance` command. GitHub CI will run after push.

## Interpretation

The shared address follows the elected primary for new connections. An existing
connection is not transferred, and HAProxy does not retry or replay SQL.
Certificate verification protects both PostgreSQL traffic and the HTTPS role
checks. During quorum loss the endpoint becomes unavailable until a suitable
primary is confirmed again.

One HAProxy instance and one Docker host remain shared failure points. The five
missing acknowledgments demonstrate the existing asynchronous-loss boundary;
stable routing does not change durability. No production workload, automatic
transaction retry, multi-host failure, or watchdog fencing were not tested.
