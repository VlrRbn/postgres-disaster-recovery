# Command Names Acceptance Evidence

- Result: PASS
- Date: `2026-10-28`
- Source: working changes on `fix/command-names`, based on `0724a9b` (`v0.11.0`)
- Environment: Linux amd64, Docker Compose, local disposable databases
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`

## Validation

The saved command renames were applied after TLS shipped as `v0.11.0`. Make
targets, script dispatch, current guides, and the health service definition were
updated together. `make -n` confirmed that the renamed public targets call the
intended scripts, including the S3 wrappers, without starting jobs.

| Check | Observed Result |
| --- | --- |
| Local backup and restore | `make acceptance` passed all six stages, including corruption detection, isolated restore, PITR, exact records, and retained writes |
| Archive-end recovery | `make rpo-acceptance` used the `latest-wal` mode: 10 acknowledged transactions, 5 recovered exactly, 5 intentionally lost after archive delivery was blocked |
| Scheduled jobs | `make schedule-acceptance` passed all nine stages with the renamed backup and backup-health entrypoints |
| Locking and failures | Scheduled lock contention and jobs against a stopped primary returned failures; healthy jobs completed successfully |
| TLS replication | `make replication-acceptance` passed all 11 stages, including insecure-connection rejection, switchover guards, fencing, offline rejoin, and recreation |
| Role-aware SQL | After roles reversed, primary/standby SQL dispatch selected the writable/read-only nodes and all 24 records matched |
| Installed unit upgrade | A test replaced an old `scheduled-health` unit, then reinstalled: the new unit called `scheduled-backup-health`, while custom schedule configuration stayed unchanged |

The RPO exercise left the source stopped during recovery and verified the archive
contents remained unchanged. Replication finished with verified TLS streaming
after the reversed topology was recreated. Both offline rewind invocations
reported `no rewind required`; this run did not exercise divergent block copying.

All disposable containers, networks, and data/repository/control volumes were
removed. Scheduling acceptance used temporary alert configuration and state;
it did not install host timers or contact real notification providers.

## Regression

`make check` passed ShellCheck, shell syntax, 67 Python test methods, four Compose
configurations, systemd unit/calendar validation, and diff formatting. The
existing schedule reinstallation test now explicitly exercises an old health
unit and preservation of operator settings. Alert integration tests use
`scheduled-backup-health` while retaining the `backup-health` incident key.

The old public commands remain only in migration instructions and historical
release notes/evidence. The legacy unit in the upgrade test is intentional.

## Interpretation

These checks verify command dispatch and existing runtime behavior after the
rename. GitHub CI remains pending.

The existing limits of single-host replication, asynchronous recovery, and
local scheduler availability remain. This change adds no new recovery or
availability guarantee.
