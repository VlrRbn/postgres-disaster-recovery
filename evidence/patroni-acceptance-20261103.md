# Patroni Acceptance Evidence

- Result: PASS
- Date: `2026-11-03`
- Source: working changes on `feat/patroni-ha`, based on `c31deae` (`v0.12.0`)
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; Patroni: `4.1.5`; psycopg2 adapter: `2.9.11`; etcd: `3.6.5`
- Test project: `postgres-dr-patroni-test-1793700974-13130`

## Validation

`make patroni-acceptance` passed all eight stages on a disposable two-node PostgreSQL
cluster with three etcd members after runtime commands, paths, and variables
were renamed to `patroni`. The clean image build on `2026-11-02` passed the
PostgreSQL version assertion, Patroni version assertion, and `pip check`; the
renamed runtime reused those validated dependency layers.

| Check | Observed Result |
| --- | --- |
| Bootstrap | One Patroni leader and one streaming replica; 20 orders matched across every stored field |
| Replica writes | Insert on the replica failed with SQLSTATE `25006` |
| PostgreSQL TLS | Streaming sender used SSL and the receiver required `sslmode=verify-full` |
| REST authentication | An unauthenticated configuration PATCH returned HTTP `401` over verified HTTPS |
| etcd authentication | Verified HTTPS with a client certificate succeeded; a request without a client certificate failed during TLS |
| Key mounts | Each database mounted its own server key and the shared DCS client key; each etcd member mounted only its own key; no CA signing key was mounted |
| Network exposure | No host port bindings on any of the five services |
| Credentials | No password environment variables in container configuration |
| Single etcd loss | Two-member majority preserved the same PostgreSQL leader and accepted writes |
| Replica isolation | Five additional orders committed on the primary while the disconnected replica still held 20 orders |
| Leader crash | SIGKILL of the leader container was followed by automatic promotion of the reconnected replica |
| Acknowledged loss | Of 25 journaled successful inserts, 20 orders and their amounts survived; references `patroni-workload-021` through `patroni-workload-025` were absent |
| New primary writes | Promoted node accepted a new order |
| Former leader | Restarted node automatically returned as a streaming replica; the five forked orders were absent and both databases matched |
| Majority loss | With two etcd members stopped, both PostgreSQL nodes were confirmed stopped or in recovery, and neither REST API advertised a primary |
| Quorum recovery | Restoring the two members recovered one leader and one streaming replica; a subsequent write succeeded |
| Recreation | Database and DCS volumes retained 22 exact rows across container recreation |
| Public SQL helpers | Role-aware primary/standby commands selected recovery states `f` and `t` after recreation; TLS/access-control checks passed again |

Observed failover time was `22.434 s`, measured monotonically from leader-container
kill through a reachable promoted primary. This includes reconnecting the replica
that the scenario deliberately isolated. It does not measure application retries
or routing through a stable endpoint.

The JSON report and all 25 acknowledgment records were saved under
`.local/reports/postgres-dr-patroni-test-1793700974-13130-patroni.json` and `.jsonl`.
Cleanup removed the five containers, five volumes, network, and temporary private
credentials. Independent Docker queries confirmed no test containers or project
volumes/networks remained. Existing runtimes and the separate playground were
not modified.

## Regression

`make check` passed 70 Python tests, ShellCheck, shell syntax, five Compose models,
systemd declarations/calendars, and diff formatting. Three Patroni tests verify
member-name validation, verified recovery settings, preservation of failed data,
and private/idempotent certificate/credential setup with actual OpenSSL. The
existing seven replication TLS tests passed through the shared setup functions.

`make acceptance` passed all six local backup, corruption-detection, isolated
restore, and PITR stages.

`make replication-acceptance` passed all 14 manual replication stages, including
TLS rejection, controlled switchover, rejoin, and WAL-loss reseeding in both
topologies with 26 exact final rows. CI YAML parsing confirmed that the required
`Foundation checks` job runs the Patroni scenario; its timeout was increased
to 15 minutes to include image building and lease/quorum waits.

## Interpretation

The results verify the tested container-crash, isolated-replica, and DCS quorum
cases on one Docker host. The five missing acknowledgments are an intentional
asynchronous-loss observation, not a permitted loss target or general upper bound.
The former leader recovered automatically with `use_pg_rewind` enabled and data
directory removal on rewind failure/divergence disabled.

Watchdog devices and external fencing are not configured. Patroni process
suspension, kernel/host failure, watchdog resets, long-term DCS recovery, and
stable application routing were not tested. Local/S3 backup workflows target
their own separate clusters. GitHub CI will execute the same Patroni command
when this change is pushed.
