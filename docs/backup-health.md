# Backup Health

Check whether the running primary has a recent completed full backup and can
deliver WAL to its pgBackRest repository now. The command prints a JSON report
and returns an error when any required check fails.

## Start, Check, And Stop

Run from the repository root:

```bash
make up
make backup
make backup-health
make down
```

`make up` generates the ignored local password, initializes the stanza, and
checks archiving. It does not create a backup. Until `make backup` succeeds,
backup health reports an absent completed copy.

The health command operates on `postgres-dr-local` by default and honors
`PGDR_PROJECT` and `PGDR_SECRET_FILE`. The primary must be running. It does not
start services, create backups, or repair an unhealthy repository.
`make down` stops the lab and retains all interactive volumes and passwords.

## Limits

| Setting | Default | Meaning |
| --- | --- | --- |
| `PGDR_BACKUP_MAX_AGE_SECONDS` | `86400` | Maximum age of the latest completed successful full backup, measured from its completion timestamp |
| `PGDR_ARCHIVE_TIMEOUT_SECONDS` | `10` | Maximum pgBackRest wait for the required WAL segment to reach the archive |

For a one-hour backup-age limit and a longer archive wait:

```bash
PGDR_BACKUP_MAX_AGE_SECONDS=3600 PGDR_ARCHIVE_TIMEOUT_SECONDS=15 make backup-health
```

Both settings require positive integer seconds; the archive timeout is limited
to `86400` seconds. The 24-hour default is a lab policy, not a guaranteed recovery
objective. Choose a limit consistent with the intended backup schedule; the lab
does not install a scheduled backup job.

Backup age uses the host UTC wall clock and pgBackRest's completion timestamp.
Age equal to the configured limit passes. A future completion timestamp fails
instead of being treated as a fresh backup. Keep the database and host clocks
correct; this age calculation is separate from monotonic recovery measurements.

## Report And Exit Codes

The report contains `schema_version`, `status`, `project`, `stanza`,
`observed_utc`, configured `limits`, individual `checks`, and `archiver` statistics.

| Check | Pass Condition |
| --- | --- |
| `repository` | pgBackRest returns readable metadata for exactly one healthy `orders` stanza |
| `backup_freshness` | A successful completed full backup exists and its completion age is within the limit |
| `wal_delivery` | Active `pgbackrest check` succeeds within the configured archive wait |
| `database` | The primary is reachable over its local socket and has WAL archiving enabled |

`status` is `healthy` only when every check is `ok`. Otherwise it is `unhealthy`,
with failed checks and details. A selected backup includes its `label`,
`completed_utc`, and `age_seconds`. Failed data collection remains a failed
check; unavailable values are not replaced by an earlier successful report.

`make backup-health` emits only JSON on stdout. Runtime failure details are part
of the report; Make also prints its failure message on stderr. Capture a snapshot
after starting the lab if needed:

```bash
make backup-health > .local/backup-health.json
```

For automation that needs exact process exit codes, invoke the script directly:

```bash
python3 scripts/backup_health.py
```

| Exit Code | Direct Python Command | Make Command |
| --- | --- | --- |
| `0` | All required checks passed | All required checks passed |
| `1` | Health failed; inspect the JSON report | Make translates a failed recipe to exit `2` |
| `2` | Invalid arguments or thresholds; usage error on stderr before Docker commands | Recipe failure also produces exit `2` |

## Active WAL Check And Statistics

The command runs `pgbackrest --stanza=orders --archive-timeout=... check`, which
forces a WAL switch and waits for the required segment in the repository.
This generates WAL activity, including on an otherwise idle database. It does
not alter application rows or create a backup. Avoid treating it as a frequent
read-only probe.

The archive timeout governs the pgBackRest wait, not the entire command duration.
Repository metadata and SQL collection each have a 30-second host timeout; the
active probe has its configured archive wait plus 30 seconds for command overhead.

The `archiver` object includes archived and failed counts, last successful and
failed WAL names and times, and the statistics reset timestamp. These values are
diagnostic: `failed_count` is cumulative, and an old `last_archived_time` can occur
on an idle system. Neither value alone fails health when current delivery works.

## Failure Handling

| Failed Condition | Operator Action |
| --- | --- |
| No completed full backup | Run `make backup`; confirm completion with `make backup-info` |
| Backup exceeds the age limit | Create a new backup and investigate the intended backup schedule |
| Metadata unavailable or unhealthy | Confirm the intended repository mount, stanza, and `make backup-info`; initialize a fresh stanza with `make backup-init` |
| WAL delivery fails or times out | Inspect `bash scripts/compose.sh logs postgres`, repository permissions and space, then retry `make backup-health` after resolving the cause |
| Primary stopped or unreachable | Start the intended primary with `make up`, then repeat the health check |
| Backup completion is in the future | Inspect host and database clocks before relying on the age result |

Healthy metadata and current archive delivery do not validate all stored backup
files or demonstrate restoration. Continue to use `make backup-verify` and the
physical restore/PITR acceptance commands.

## Acceptance

```bash
make check
make backup-health-acceptance
```

The standalone scenario uses a unique `postgres-dr-health-test-*` Compose
project and temporary password. It verifies:

- Missing stanza metadata and an initialized repository without a backup fail.
- A fresh completed full backup and active WAL delivery pass.
- A real backup becomes stale under a one-second test limit, without metadata edits.
- Write restrictions on the disposable archive cause current delivery to fail
  while the completed backup remains fresh and readable.
- Restoring permissions and restarting the test primary restores healthy delivery;
  historical error counts remain present and do not cause a false failure.
- The synthetic order and completed backup label are retained.
- A stopped primary yields valid unhealthy JSON and a nonzero exit code.

After successful checks, all seven reports are saved in an ignored
`.local/reports/postgres-dr-health-test-*-health.json` acceptance report. The exit
handler removes only that test project's containers, network, volumes, and
temporary password. Images remain cached. No separate shutdown is needed.
CI runs the same command and prints the saved report.

## Scope

This is an on-demand detection command for the existing local backup repository.
It does not install a scheduler, send notifications, or provide a monitoring
dashboard. A healthy snapshot establishes the checked conditions at that run;
backup integrity, restore capability, off-host durability, and recovery objectives
remain separate contracts.

## References

- [pgBackRest Check Command](https://pgbackrest.org/command.html#command-check)
- [pgBackRest Backup Information And Monitoring](https://pgbackrest.org/user-guide.html#monitor)
- [PostgreSQL Archiver Statistics](https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-PG-STAT-ARCHIVER-VIEW)
