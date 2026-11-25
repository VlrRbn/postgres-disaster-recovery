# Patroni Bootstrap Acceptance Evidence

- Result: PASS
- Date: `2026-11-25`
- Source: working changes on `fix/startup-readiness`, based on `9883e15`
- Environment: local Docker Compose, fresh PostgreSQL and DCS volumes
- Versions: PostgreSQL `17.11`, Patroni `4.1.5` with the gateway compatibility patch, etcd `3.6.5`
- Test project: `postgres-dr-patroni-test-1795606528-121412`

## Validation

`python3 scripts/patroni_acceptance.py` passed all eight stages. Its initial
bootstrap starts only etcd1, both PostgreSQL nodes, and HAProxy. It then adds
etcd2 to establish a majority; etcd3 has not run at this point.

| Check | Observed Result |
| --- | --- |
| Single DCS member | Readiness reached its deadline and SQL through HAProxy was refused |
| Fresh two-member quorum | Readiness accepted two healthy etcd members, one leased primary, and verified TLS SQL through HAProxy |
| Bootstrap versions | The responding server reported `etcdserver=3.6.5`, `etcdcluster=3.0.0`; the client used the supported `/v3` gateway |
| First write | An insert and delete succeeded through HAProxy before etcd3 was started |
| Third-member join | etcd3 joined successfully; both PostgreSQL nodes reached streaming replication |
| Transport and identity | Replication TLS, REST authentication, DCS mutual TLS, and rejection of incorrect proxy certificate identities passed |
| Automatic failover | A leader crash promoted the replica and new SQL connections reached it through the same HAProxy endpoint |
| Former leader | The restarted node rejoined as a streaming replica |
| Quorum loss and recovery | Losing two etcd members removed the writable primary and SQL route; restoring quorum recovered replication and writes |
| Recreation | Recreated containers retained 22 matching orders, TLS checks, and role-aware SQL access |

The asynchronous-loss exercise acknowledged 25 orders and intentionally isolated
the replica before the final five writes. Twenty orders survived promotion;
references `patroni-workload-021` through `patroni-workload-025` were absent.

## Regression

The image build passed eight gateway-version cases against the actual patched
Patroni client, including rejection of unsupported versions. The patch preserves
the reported cluster feature version and refuses an unexpected Patroni version
or source target.

`make check` passed all 93 Python tests, ShellCheck, shell syntax, seven Compose
configurations, systemd definitions/calendars, and diff formatting.

## Cleanup

The scenario removed its containers, volumes, networks, and temporary private
directory. Independent Docker queries confirmed zero remaining resources with
this project's label, including stopped containers.

The JSON report and acknowledgment journal remain in `.local/reports/` under
the test project's name. Existing environments were not used, and no AWS
operations were performed. This run verifies the recorded container and quorum
cases on one host; it does not establish resilience to losing that host.
