# Backup Scheduling Acceptance Evidence

- Result: PASS for unit definitions, installer safety, scheduled job entrypoints, and host service/timer validation
- Date: `2026-10-20`
- CI and review: [PR #15](https://github.com/VlrRbn/postgres-disaster-recovery/pull/15)
- Source: working changes on `feat/scheduled-backups`, based on `25d8c68`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- systemd tools: `255`; PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Host user timers installed/enabled by acceptance: no

## Validation

`make schedule-acceptance` passed the existing six backup-health stages and three
additional scheduling stages on a unique disposable Docker project. The actual
systemd parser accepted all four units and both UTC calendar expressions.

| Check | Observed Result |
| --- | --- |
| Existing health detection | Missing repository/backup, stale backup, archive outage, recovery, and stopped primary checks passed |
| Scheduled full backup | The same Make entrypoint referenced by the service created a completed full backup and verified repository integrity |
| Scheduled health | Stdout parsed as JSON with `status=healthy` and the completed backup |
| Data preservation | The synthetic order remained present after scheduled jobs |
| Shared project lock | A held lock made the second job return `75` after a one-second test wait, with a diagnostic |
| Stopped-primary backup | Scheduled backup returned nonzero |
| Stopped-primary health | Scheduled health returned nonzero and emitted valid `status=unhealthy` JSON |
| Cleanup | Disposable containers, network, volumes, password, and project lock removed |

Six installer tests use temporary configuration directories and a stubbed
`systemctl` that allows only reload and state inspection. Installation creates
mode-`0600` config and never requests timer activation. Reinstall preserves edited
config. Removal retains the config and refuses an activating job or unavailable
manager state. A checkout path containing spaces, percent signs, dollar signs,
and quotes is preserved in the generated configuration.

Six stop-all tests use stubbed Docker and systemd commands. They check checkout
and project selection, manual backup and worker detection, active scheduled-job
refusal, manager/listing errors, and an empty successful no-op. These tests do not
stop real containers or establish live shutdown behavior. `make help` and plain
`make` both display grouped command help without starting services.

## Regression

`make check` passed shell validation, 38 Python unit test methods, all Compose
configurations, systemd definitions and calendars, and diff formatting.

`make acceptance` passed existing database persistence, backups, corrupt-copy
detection, physical restore, unsafe-target/missing-WAL rejection, and PITR. Its
PITR comparison recovered 22 exact records and verified recovered-side writes
survived restart. Its disposable resources were removed.

## Systemd Service And Timer Validation — 2026-10-20

Sources: service command output and user-journal entries from the existing
`postgres-dr-local` runtime. Times below are UTC; journal headers displayed Irish
local time, one hour ahead on this date.
This is a separate host exercise from the automated disposable runs above.

| Check | Observed Result |
| --- | --- |
| Installation | Four user units installed; private configuration selected the local project and repository |
| Backup service | Journal recorded completion at `20:09:22`; backup `20261020-200918F` completed at `20:09:21` |
| Retention and integrity | Oldest backup `20261020-165908F` expired; two backups remained, with 1270 valid files each and 15 valid WAL segments |
| Manual health service | `status=healthy` at `20:14:37`, with a 93600-second age limit and successful active WAL delivery |
| Timer enablement | Both timers enabled; next calendar activations shown by `list-timers` |
| Temporary health timer | A 30-second runtime timer override triggered another healthy invocation, recorded in the journal at `20:21:29` |
| Override cleanup | Unit output subsequently showed the original `OnCalendar=*-*-* *:15,45:00 UTC`, without the temporary drop-in |
| Stopped primary | At `20:31:03`, health returned `unhealthy`; systemd recorded `Result=exit-code`, `ExecMainStatus=2`, and `ActiveState=failed` |
| Recovery | After `make up` and a service retry, health returned `healthy` at `20:33:38`, still referencing backup `20261020-200918F` |

Completed services showed an empty `ExecMainExitTimestamp`; journal completion,
backup metadata, and health JSON supplied the execution evidence. The stopped
primary also prevented repository inspection: the freshness message about no
available backup in that failed report did not establish that backups were lost.
Normal calendar firing, logout/reboot persistence, and missed-run catch-up were
not exercised. Live `stop-all` behavior is not established by these excerpts.

## Interpretation

Automated checks verify unit declarations and job behavior without a live user
manager. Host validation adds service and journal evidence,
a temporary health-timer run, and a failure/recovery cycle on the host. It does
not establish daily or half-hourly calendar firing, user-manager persistence
across logout/reboot, or missed-run catch-up.

Scheduling is limited to an available local primary. S3 scheduling, starting the
database after reboot, external alert delivery, and recovery objectives are
outside this change.
