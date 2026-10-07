# PostgreSQL Disaster Recovery

A PostgreSQL recovery lab built in small, verifiable milestones. It combines a
database image built from a digest-pinned base, persistent storage, WAL archiving,
physical backups, isolated restore, PITR, and measured recovery results.

## Project Status

Released capabilities run on one Docker host:

| Release | Capability |
| --- | --- |
| `v0.1.0` | Local PostgreSQL Foundation |
| `v0.2.0` | Physical Backup And Restore |
| `v0.3.0` | Point-In-Time Recovery |
| `v0.4.0` | Recovery Measurement |
| `v0.5.0` | Backup Health |

```text
empty database volume
  -> PostgreSQL initialization and readiness
  -> pgBackRest repository initialization and WAL archive check
  -> validated order records and a full physical backup
  -> container recreation with both volumes retained
  -> stop the source and restore into a separate empty volume
  -> exact record comparison, new writes, and failure detection
```

Recovery to a selected UTC time before accidental deletion and acknowledged-loss
measurement are implemented. `make backup-health` checks backup freshness and
current WAL delivery. The next milestone adds an external AWS S3 repository and
recovery on a clean replacement host; its S3 backup and WAL delivery step is
verified locally.

## Local PostgreSQL Foundation

Docker Compose builds the database image from the official PostgreSQL 17.11
Debian Bookworm base pinned to a multi-platform digest. The Dockerfile installs
pgBackRest `2.59.1-1.pgdg12+1` and verifies that PostgreSQL was not upgraded.
A named volume stores the database files. Initialization enables data page
checksums and creates the `orders` table.

The official entrypoint and database startup behavior are inherited.
See [pgBackRest image](docs/pgbackrest-image.md) for the build and version contract.

| Field | Contract |
| --- | --- |
| `id` | Generated identity and primary key |
| `reference` | Required, unique text value |
| `amount_cents` | Required integer greater than zero |
| `created_at` | Required timestamp with time zone, populated on insert |

A health check waits for PostgreSQL to accept TCP connections inside the
container. Startup and recreation use a 120-second readiness deadline.
See [local foundation acceptance](docs/local-foundation-acceptance.md) for the
verification contract.

## Persistence Exercise

The acceptance script creates a separate Compose project and inserts 20 orders.
It captures every stored field, recreates the database container on the same
volume, and requires the replacement to have a different container ID. The two
ordered CSV snapshots must match byte for byte, and a new insert must succeed.

The same run checks that data checksums are enabled and that PostgreSQL rejects
a negative order amount with SQLSTATE `23514`. The completed local run is recorded
in [foundation evidence](evidence/local-foundation-acceptance-20260924.md).
The derived image passes the same scenario and verifies both PostgreSQL and
pgBackRest versions; see [image acceptance evidence](evidence/pgbackrest-image-acceptance-20260925.md).

## Backup Repository And WAL Archiving

A separate `pgrepo` volume stores pgBackRest backups and archived WAL. `make up`
initializes the `orders` stanza and verifies that PostgreSQL can archive a WAL
segment. `make backup` creates a full physical backup and checks repository
integrity. Retention keeps two completed full backups and expires older copies
after a subsequent successful backup.

The acceptance scenario also rejects missing repository metadata, an empty
backup set, and a deliberately damaged file in its disposable test repository.
See [backup operations](docs/backup-wal-archiving.md) and
[acceptance evidence](evidence/backup-wal-acceptance-20260925.md).

## Physical Restore

`make restore` requires an explicit full backup label and an empty `pgrestore`
volume. It recovers the selected backup to its first consistent state, then
starts an isolated database with WAL archiving disabled. The repository is
mounted read-only, and the restored service has no external network access.

Acceptance restores all 20 original records while the source is stopped,
excludes a later source write, and verifies new writes and restart on the
restored database. It also rejects an occupied target and missing required WAL.
See [physical restore](docs/physical-restore.md) and
[restore evidence](evidence/physical-restore-acceptance-20260928.md).

## Point-In-Time Recovery

`make restore-time` accepts an explicit `BACKUP_LABEL` and `RECOVERY_TIME` in UTC.
It replays archived WAL to the selected time in the same isolated restore service.
The target must follow the end of the selected backup and be reachable from the
available WAL. An unreachable target fails without claiming successful recovery.

The acceptance scenario preserves post-backup orders while excluding a later
deletion and insert. See [PITR operations and acceptance](docs/point-in-time-recovery.md)
for preparation, commands, and the recovery boundary.

## Recovery Measurement

`make acceptance` records the successful PITR attempt from restore invocation
through exact data validation and a confirmed new write. A JSON report in
`.local/reports/` records duration using a monotonic clock, UTC boundaries,
recovered row counts, and deliberately excluded rows. It is printed in CI.

The report distinguishes the chosen rollback window from crash RPO. See
[measurement boundaries](docs/recovery-measurement.md) for commands, fields,
conditions, and interpretation.

`make rpo-acceptance` records ten acknowledged transactions, simulates a WAL
archive outage and primary crash, and compares recovery with the host journal.
Its JSON report measures acknowledged loss and the interval from the last
recovered acknowledgment to the fault trigger. See
[acknowledged workload and RPO](docs/acknowledged-workload-rpo.md).
`BACKUP_LABEL=YYYYMMDD-HHMMSSF make restore-latest` recovers the selected backup
to the end of available archived WAL.

## Backup Health

`make backup-health` prints a JSON report and succeeds only when the running
primary has a completed full backup within the configured age limit and an
active WAL delivery check succeeds. Defaults are a 24-hour backup age limit
and a 10-second WAL archive timeout. The check forces a WAL switch.

The report includes archiver statistics for diagnosis. Historical errors and
an old archive timestamp alone do not fail a successful active check.
See [backup health operations](docs/backup-health.md) for limits, exit codes,
failure handling, and the standalone acceptance scenario.

## AWS S3 Repository

The optional [AWS S3 runtime](docs/s3-repository.md) uses a dedicated Terraform
bucket and prefix-scoped IAM writer role. `make s3-up`, `make s3-backup`, and
`make s3-check` send backup data and WAL outside the database host through
verified HTTPS. `make s3-down` retains the S3 objects and the separate local
database volume. Clean-host recovery is the next delivery step.

## Security Defaults

- official PostgreSQL base image pinned to an immutable digest;
- pgBackRest package installed at an exact reviewed version;
- generated local password stored outside Git with file mode `0600`;
- password mounted through a Compose file secret;
- internal database network with no published host port;
- CPU, memory, and shared-memory limits;
- isolated database resources for automated acceptance.

## Optional Database Interface

Run `make pgadmin-up` and open <http://127.0.0.1:5050> for the primary database's
pgAdmin interface. The `.local` directory and both password files are generated
automatically on first startup; no manual setup is needed. Existing passwords
are preserved on subsequent runs, and the files are ignored by Git.

Sign in as `admin@example.com` with the password from
`.local/pgadmin_password`; use `.local/postgres_password` when connecting to the
preconfigured **Orders — primary** server. See [pgAdmin operations](docs/pgadmin.md)
for table browsing, SQL, ports, passwords, and cleanup.

`make pgadmin-down` stops only the UI. Normal `make up` does not start it.
The restored database remains accessible through `make restore-psql`.

## Prerequisites

```text
Linux
Docker Engine
Docker Compose v2 or newer
Docker Buildx
Bash
Python 3
Make
Git
ShellCheck
```

The first build downloads the pinned PostgreSQL base and packages from the
Debian and PostgreSQL APT repositories.

## Local Commands

Run these commands from the repository root. The interactive examples use the
default Compose project `postgres-dr-local`.

| Command | What It Does | What Remains Afterwards |
| --- | --- | --- |
| `make check` | Check shell scripts, Compose configuration, and diff formatting | No database is started |
| `make image` | Build the PostgreSQL image with pgBackRest | Local image and build cache; no database is started |
| `make up` | Generate or reuse the password, build and start PostgreSQL, initialize the repository, and check WAL archiving | Database running with initialized backup storage; no backup yet on first startup |
| `make psql` | Open a SQL session in the running database | Database stays running when the session closes |
| `make acceptance` | Test persistence, backup, isolated restore, and failure detection | Test images and build cache; test containers, network, and all three volumes removed |
| `make down` | Stop and remove both database containers and the project network | Source, backup, and restore volumes, password file, images, and build cache |
| `make backup-init` | Initialize or reuse the stanza and check WAL archiving; also run by `make up` | Repository metadata and archived WAL |
| `make backup-check` | Force a WAL switch and wait for the segment to reach the repository | New archived WAL; no backup is created |
| `make backup` | Check archiving, create a full backup, apply retention, and verify repository integrity | Completed physical backup and required WAL |
| `make backup-info` | Display available backups and WAL ranges | Existing data and backups unchanged |
| `make backup-verify` | Verify completed backup files and archives; reject empty or invalid results | Existing data and backups unchanged |
| `make backup-health` | Report completed backup freshness, database reachability, and active WAL delivery as JSON | Database stays running; a WAL switch can add archived WAL; no backup is created |
| `make backup-health-acceptance` | Verify health, missing or stale backup, archive outage, recovery, and stopped primary | JSON evidence retained under `.local/reports/`; disposable containers, network, volumes, and password removed |
| `make s3-up` | Refresh writer credentials, build/recreate the separate S3 primary, initialize its stanza, and check S3 WAL delivery | S3 primary running; password, private config, database volume, and S3 objects retained |
| `make s3-backup` | Create and verify a full backup in the configured AWS S3 prefix | Full backup and required WAL in S3 |
| `make s3-health` | Report S3 backup freshness and current WAL delivery as JSON | S3 primary running; active probe can add WAL |
| `make s3-down` | Remove only the S3 lab containers and networks | S3 objects, S3 lab database volume, settings, and passwords retained |
| `make s3-acceptance` | Verify S3 API backup and WAL through an isolated local TLS fixture | JSON report and cached images retained; fixture containers, networks, volume, and temporary secrets removed |
| `BACKUP_LABEL=... make restore` | Restore the selected full backup into an empty target and wait for recovery to finish | Restored database running; source data and repository unchanged |
| `make restore-psql` | Open a SQL session in the restored database | Restored database stays running after `\q` |
| `make restore-down` | Stop and remove only the restored container | All volumes retained; source container unaffected |
| `make restore-up` | Resume the existing restored database | Restored database running; no new restore is performed |

`make up` already builds the image, so a separate `make image` is optional.
`make acceptance` is a standalone test and does not require `make up` first.

## Run The Local Foundation

Check the project, then start the interactive database:

```bash
make check
make up
```

The startup command returns after PostgreSQL is healthy and the repository and
WAL checks pass. It does not create a backup automatically. PostgreSQL continues
running in the background. Inspect its status and follow its logs:

```bash
bash scripts/compose.sh ps
bash scripts/compose.sh logs --follow postgres
```

Press `Ctrl+C` to stop following logs. The database keeps running.

Open a SQL session:

```bash
make psql
```

Insert and inspect an order, then exit `psql`:

```sql
INSERT INTO orders (reference, amount_cents) VALUES ('demo-001', 1250);
SELECT * FROM orders;
\q
```

Use a new reference for each additional order. `\q` closes the SQL session;
it does not stop PostgreSQL.

Check the installed backup tool while the database container is running:

```bash
bash scripts/compose.sh exec --user postgres postgres pgbackrest version
```

Expected output: `pgBackRest 2.59.1`.

## Create And Inspect A Backup

With the interactive database running, create a full backup:

```bash
make backup
make backup-info
```

`make backup` checks WAL delivery, creates the copy, and prints an integrity
report with `status: ok`. `make backup-info` shows the completed backup label
and WAL range. Backups cover the whole PostgreSQL cluster, including `orders`.

To repeat the checks separately:

```bash
make backup-check
make backup-verify
```

`make backup-check` verifies current WAL delivery; it does not create a backup.
`make backup-verify` checks existing copies and fails if none exists or a file is
invalid. Neither command restores data. See [backup operations](docs/backup-wal-archiving.md)
for configuration, retention, and troubleshooting.

Check backup age and current archive delivery together:

```bash
make backup-health
```

The primary must be running. A healthy result does not replace integrity
verification or a restore exercise. Configure the limits using
[backup health operations](docs/backup-health.md).

## Restore Into A Separate Database

Create a backup and copy its full label from the output:

```bash
make up
make backup
make backup-info
make down
```

Replace `YYYYMMDD-HHMMSSF` with that exact label, then restore and inspect:

```bash
BACKUP_LABEL=YYYYMMDD-HHMMSSF make restore
make restore-psql
```

```sql
SELECT pg_is_in_recovery();
SELECT * FROM orders ORDER BY id;
\q
```

Recovery must be complete (`pg_is_in_recovery` returns `f`). The source remains
stopped in this sequence. Stop the restored database when finished:

```bash
make restore-down
```

Use `make restore-up` to resume it. A second `make restore` refuses to overwrite
its files; see [repeat restore and cleanup](docs/physical-restore.md#repeat-restore-and-cleanup)
for deliberately discarding only the restored copy.

## Stop And Resume The Lab

Stop the database services and optional pgAdmin, removing their containers and
the project network:

```bash
make down
```

All named volumes (`pgdata`, `pgrepo`, `pgrestore`, and `pgadmin_data` when created)
and local password files are retained. To resume the source:

```bash
make up
make psql
```

Run `SELECT * FROM orders;` to inspect the retained rows. Exit with `\q` and
run `make backup-info` to inspect retained backups. Run `make down` when finished.

## Remove The Local Image

After building with `make image`, remove the default interactive image with:

```bash
docker image rm postgres-dr-local-postgres:latest
```

If the image is used by the interactive container, run `make down` first.
The image name above assumes the default project; a `PGDR_PROJECT` override
changes the generated image name. If you also built the restore service, its
image can be removed after `make down`:

```bash
docker image rm postgres-dr-local-restore:latest
```

Removing an image does not delete any data volume, local password, or
Docker build cache. The next `make up` rebuilds the image and reuses the retained
volume. After deleting the restore image, rebuild it with
`bash scripts/compose.sh build restore` before using `make restore-up`.
Images built by acceptance use separate `postgres-dr-test-*` names.

## Run The Acceptance Checks

Run the complete disposable scenario, including its image build:

```bash
make check
make acceptance
```

On success, the command prints the version, backup, persistence, and restore
`PASS` messages and removes its test containers, network, and all three volumes.
A separate `make down` is not needed for acceptance.
If cleanup fails, the command reports the test project and retained secret path.

## Capability Status

| Capability | Status |
| --- | --- |
| Local PostgreSQL deployment | Released in `v0.1.0` |
| Container recreation and data comparison | Released in `v0.1.0` |
| Pull-request CI | Active |
| PostgreSQL image with pgBackRest | Complete |
| Physical backup and WAL archiving | Released in `v0.2.0` |
| Restore into an empty volume | Released in `v0.2.0` |
| Point-in-time recovery | Released in `v0.3.0` |
| Verified recovery duration and acknowledged-loss measurement | Released in `v0.4.0` |
| Backup freshness and active WAL delivery health | Released in `v0.5.0` |
| AWS S3 full backup and WAL storage | Verified locally; PR validation pending |
| Recovery from S3 on a clean replacement host | Planned |

See the [delivery roadmap](docs/roadmap.md) for milestone scope,
[contribution guidelines](CONTRIBUTING.md) for the PR workflow, and
[release procedure](docs/releasing.md) for publishing verified milestones.

## Safety Boundary

The interactive lab uses Compose project `postgres-dr-local` by default.
`make acceptance` creates its own temporary project, password, and three volumes.
Its exit handler removes those test resources; if cleanup fails, it reports the
project and retained secret path for manual inspection. It does not use the
interactive lab's volumes. The corruption test modifies only a file in the
disposable backup repository and replaces it with the saved original before
the final integrity check. The missing-WAL test temporarily withholds one
segment in that same disposable repository, then puts it back.

`make down` retains all interactive volumes. Initialization SQL runs only when
the volume is empty, so editing the SQL file does not migrate an existing database.
Repeating password setup preserves the local file and does not rotate the
password in an initialized database.

## Production Boundaries

The default local runtime stores backups and WAL on the database's Docker host.
The optional S3 runtime stores them in AWS with SSE-S3 encryption and bucket
versioning. Neither runtime installs backup scheduling. Retention is configured
and S3 expiration is exercised with three full backups and recovery from the
oldest retained copy. Local repository retention rollover remains untested.
Package dependencies resolve from live APT repositories.

The current checks prove backup creation, WAL delivery, file integrity, PITR,
and restore into a separate volume with the source stopped. A controlled primary
crash exercise measures acknowledged loss during archive-only recovery. Both
databases and the local repository still share one host. S3 backup creation and
current WAL delivery are separately verified, including restricted IAM access.
Backup health runs on demand; no scheduler or alert transport is installed.

SQL exercises use the bootstrap administrator over the local container socket.
Application roles and remote authentication are not yet covered. Compose file
secrets are local files rather than an encrypted secret manager.
