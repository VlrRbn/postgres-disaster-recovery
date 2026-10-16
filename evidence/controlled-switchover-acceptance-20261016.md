# Controlled Switchover Acceptance Evidence

- Result: PASS
- Date: `2026-10-16`
- Source: working changes on `feat/controlled-switchover`, based on `cacfa68`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`

## Validation

`make replication-acceptance` passed all ten stages on its own disposable project.
The first six repeated the existing streaming, read-only, outage, target-guard,
and 22-row persistence checks. The remaining stages exercised controlled
promotion, saved fencing, offline rejoin, and reversed-role startup.

| Check | Observed Result |
| --- | --- |
| Premature rejoin | Rejected before a standby was promoted |
| Paused replay | Promotion rejected; original primary remained writable and standby stayed in recovery |
| Promotion | Target `0/30078D8` replayed; old primary stopped; standby became writable |
| Timeline | Promoted node's checkpoint timeline increased from the original timeline |
| Old-primary startup | One-off ordinary startup rejected with `Old primary is fenced` |
| Startup after promotion | Only the promoted node resumed; original primary stayed stopped |
| New write | Promoted node accepted order 23; it survived full container removal and startup |
| Offline rejoin | New primary stopped cleanly; old target and read-only source checked by `pg_rewind` dry run and normal invocation |
| Rewind path | Both invocations reported `no rewind required` after checking the divergence point |
| Rejoined role | Original primary returned `pg_is_in_recovery()=t` and used slot `primary` |
| Rejoined writes | Insert rejected with SQLSTATE `25006` |
| Reversed streaming | New primary sent subsequent WAL to the original primary; all 24 rows matched as ordered CSV including every field |
| Recreation | Both containers recreated; service `standby` stayed writable and service `primary` stayed read-only |
| SQL commands | Primary and standby SQL commands selected the current roles after reversal |
| Repeated promotion | Rejected after completed reversal |

Final status showed application `primary`, sender state `streaming`, mode `async`,
zero reported replay lag, and an active `primary` physical slot. The old primary's
WAL receiver was streaming through that slot. Cleanup removed both containers,
the network, both data volumes, the control volume, and temporary secrets.

## Regression

`make check` passed shell syntax, ShellCheck, 26 existing Python unit test methods,
all four Compose configurations, and diff formatting.

`make acceptance` passed database persistence, full backup, corrupt-copy detection,
physical restore, unsafe-target and missing-WAL rejection, and PITR. The existing
PITR scenario recovered 22 exact records and confirmed recovered-side persistence.
Its disposable containers, network, and three volumes were removed.

## Interpretation

The result verifies a planned role change with stopped application writers and
short local outages. The offline rewind checks found no target changes requiring
block copying. Recovery of a genuinely divergent or damaged old primary, missing
rewind WAL, and failure during an in-progress rewind remain unverified.

Both nodes share a Docker host. Startup fencing is a local workflow guard and
does not establish distributed fencing, automatic failover, application routing,
or zero-loss recovery from an uncontrolled failure.
