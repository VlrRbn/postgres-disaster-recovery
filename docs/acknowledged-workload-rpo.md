# Acknowledged Workload And RPO

This exercise measures acknowledged data lost when the archive cannot accept
new WAL and recovery uses the last available archive after a primary crash.
It complements the [PITR duration report](recovery-measurement.md), which measures
an intentional rollback rather than a crash recovery point.

## Run The Scenario

```bash
make check
make rpo-acceptance
```

The command creates its own Compose project, password, database, repository,
and restore volume. It does not use the interactive lab's data. The sequence is:

```text
empty primary and full backup
  -> acknowledge five orders and verify WAL delivery
  -> make the disposable WAL archive unwritable, while keeping it readable
  -> acknowledge five more orders and confirm an archive-write failure
  -> record the fault boundary and send SIGKILL to the primary
  -> restore the selected backup to the end of available archived WAL
  -> compare complete rows with the host acknowledgment journal
  -> confirm a new recovered-side write and report observed loss and duration
  -> remove disposable containers, network, volumes, and secret
```

The primary must have `synchronous_commit = on` and `fsync = on`. Each order
uses a separate autocommit INSERT. After psql exits successfully, the host records
the returned row, a UTC observation timestamp, and a monotonic timestamp. The
journal is flushed and fsynced after each acknowledgment, outside database volumes.
This is a short, sequential workload with a fixed five/five archive boundary.

## Read The Artifacts

The command prints its report path and measured values. Files remain in ignored
`.local/reports/` after successful cleanup:

- `postgres-dr-rpo-test-TIMESTAMP-PID-acknowledgments.jsonl`: ten observed
  acknowledgments and their complete synthetic rows.
- `postgres-dr-rpo-test-TIMESTAMP-PID-rpo.json`: counts, lost references,
  timestamps, measurement boundaries, backup label, and source information.

Use the exact name printed for your run:

```bash
python3 -m json.tool .local/reports/postgres-dr-rpo-test-TIMESTAMP-PID-rpo.json
```

CI runs the same scenario and prints the report. Failed runs may retain a partial
journal, but no verified RPO report is generated before validation succeeds.

## RPO Boundary And Interpretation

| Field | Definition |
| --- | --- |
| Acknowledgment | Host observation after a successful autocommit psql exit; includes client/process overhead |
| Fault trigger | Host stamp immediately before requesting SIGKILL; all workload writes have already finished |
| Recovered frontier | Last acknowledgment in the exactly recovered, ordered prefix |
| `lost_acknowledged_transactions` | Acknowledged journal rows absent from recovered data |
| `observed_rpo_seconds` | Fault trigger minus the last recovered acknowledgment on the host monotonic clock, when any acknowledgments are lost |
| `last_recovered_ack_to_fault_seconds` | Same interval, retained even when all acknowledgments are recovered |
| `recovery_duration_seconds` | Restore invocation through exact prefix comparison and a new write read back successfully |

If every acknowledgment is recovered, observed data loss is zero and
`observed_rpo_seconds` is `0`; idle time alone is not counted as lost data.
The report rejects non-prefix recovery, changed fields, unknown rows, duplicate
references, unordered acknowledgments, or invalid fault/recovery boundaries.
This exercise requires at least one recovered acknowledgment to define its frontier.

The fault is deliberately triggered after the archive outage and after quiescing
the workload. The host stamps are observations, not exact PostgreSQL commit times
or the exact instant the kernel terminates the server. Durations include the
intervening checks and process overhead. Report these values with these boundaries
when discussing RPO and RTO; they do not establish production objectives.

The original primary disk normally retains locally durable commits. This test
treats that disk as unavailable to the recovered instance and measures archive-only
recovery. Keeping the original volume present proves that the recovery path does
not quietly reuse it.

## Restore To The Latest Available WAL

The scenario adds an interactive restore mode. Use an explicit full backup label
and an empty restore target, following the [physical restore preparation](physical-restore.md):

```bash
BACKUP_LABEL=YYYYMMDD-HHMMSSF make restore-latest
make restore-psql
```

`latest` means the end of the available archive on the selected backup's timeline;
the backup itself is explicitly selected. pgBackRest uses `--type=default` and
`--target-timeline=current`. Recovery can succeed with a stale archive, so readiness
alone is insufficient evidence of complete data recovery.

`make restore` still targets the backup's first consistent state.
`make restore-time` still targets a specified UTC time. All three modes use the
same isolated service, reject occupied targets, and mount the repository read-only.
Stop it with `make restore-down`, resume with `make restore-up`, and follow
[repeat restore](physical-restore.md#repeat-restore-and-cleanup) to replace its data.

## Safety And Acceptance

Archive permissions are changed only inside the unique disposable test repository.
Its existing archive file paths and hashes must remain unchanged across the outage,
crash, and restore. The test confirms primary exit code `137` and keeps it stopped.
The original data volume remains present, but recovery mounts only `pgrestore`
and the repository. Docker inspection verifies the read-only repository, absence
of the source data mount, and network mode `none`.

Acceptance requires exactly ten acknowledged source rows, five exactly recovered
rows, and five lost acknowledgments. A recovered-side write must succeed. Report
creation follows these checks. Test cleanup deletes the disposable volumes,
including its original source volume and permission-modified archive; it does
not delete the host acknowledgment journal or JSON report. Images remain local.

## References

Completed local run: [RPO acceptance evidence](../evidence/rpo-acceptance-20261002.md).

- [PostgreSQL continuous archiving](https://www.postgresql.org/docs/17/continuous-archiving.html)
- [pgBackRest restore command](https://pgbackrest.org/command.html#command-restore)
