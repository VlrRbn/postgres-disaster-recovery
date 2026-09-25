# PostgreSQL Disaster Recovery

A PostgreSQL recovery lab built in small, verifiable milestones. The implemented
local foundation combines a database image built from a digest-pinned base,
persistent storage, WAL archiving, physical backups, and repeatable verification.

## Project Status

The **Local PostgreSQL Foundation** is released as `v0.1.0`. Work toward `v0.2.0`
adds a locally verified backup repository and WAL archiving on one Docker host:

```text
empty database volume
  -> PostgreSQL initialization and readiness
  -> pgBackRest repository initialization and WAL archive check
  -> validated order records and a full physical backup
  -> container recreation with both volumes retained
  -> record comparison, new writes, and backup integrity checks
```

Backup restoration, point-in-time recovery, and RPO/RTO measurement remain
planned. Release `v0.2.0` follows the separate restore acceptance step.

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

## Security Defaults

- official PostgreSQL base image pinned to an immutable digest;
- pgBackRest package installed at an exact reviewed version;
- generated local password stored outside Git with file mode `0600`;
- password mounted through a Compose file secret;
- internal database network with no published host port;
- CPU, memory, and shared-memory limits;
- isolated database resources for automated acceptance.

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
| `make acceptance` | Test persistence, WAL archiving, a full backup, and failure detection in a separate project | Test image and build cache; test container, network, and both volumes removed |
| `make down` | Stop and remove the interactive container and network | Database and backup volumes, password file, image, and build cache |
| `make backup-init` | Initialize or reuse the stanza and check WAL archiving; also run by `make up` | Repository metadata and archived WAL |
| `make backup-check` | Force a WAL switch and wait for the segment to reach the repository | New archived WAL; no backup is created |
| `make backup` | Check archiving, create a full backup, apply retention, and verify repository integrity | Completed physical backup and required WAL |
| `make backup-info` | Display available backups and WAL ranges | Existing data and backups unchanged |
| `make backup-verify` | Verify completed backup files and archives; reject empty or invalid results | Existing data and backups unchanged |

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

## Stop And Resume The Lab

Stop the interactive database and remove its container and network:

```bash
make down
```

Both named volumes (`pgdata` and `pgrepo`) and `.local/postgres_password` are
retained. To resume:

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
changes the generated image name.

Removing an image does not delete the database or backup volume, local password, or
Docker build cache. The next `make up` rebuilds the image and reuses the retained
volume. Images built by acceptance use separate `postgres-dr-test-*` names.

## Run The Acceptance Checks

Run the complete disposable scenario, including its image build:

```bash
make check
make acceptance
```

On success, the command prints the version and persistence `PASS` messages and
removes its test container, network, database volume, and backup volume. It does not leave a test
database running, so a separate `make down` is not needed for acceptance.
If cleanup fails, the command reports the test project and retained secret path.

## Capability Status

| Capability | Status |
| --- | --- |
| Local PostgreSQL deployment | Complete locally |
| Container recreation and data comparison | Complete locally |
| Pull-request CI | Active; backup changes await PR validation |
| PostgreSQL image with pgBackRest | Complete |
| Physical backup and WAL archiving | Complete locally |
| Restore into an empty volume | Planned |
| Point-in-time recovery | Planned |
| RPO/RTO measurement | Planned |

See the [delivery roadmap](docs/roadmap.md) for milestone scope,
[contribution guidelines](CONTRIBUTING.md) for the PR workflow, and
[release procedure](docs/releasing.md) for publishing verified milestones.

## Safety Boundary

The interactive lab uses Compose project `postgres-dr-local` by default.
`make acceptance` creates its own temporary project, password, and two volumes.
Its exit handler removes those test resources; if cleanup fails, it reports the
project and retained secret path for manual inspection. It does not use the
interactive lab's volumes. The corruption test modifies only a file in the
disposable backup repository and replaces it with the saved original before
the final integrity check.

`make down` retains both interactive volumes. Initialization SQL runs only when
the volume is empty, so editing the SQL file does not migrate an existing database.
Repeating password setup preserves the local file and does not rotate the
password in an initialized database.

## Production Boundaries

Backups and WAL are stored on the same Docker host as the database, without
repository encryption, scheduling, or off-host replication. Retention is
configured but multi-backup expiration is not exercised by the current acceptance
run. Package dependencies resolve from live APT repositories.

The current checks prove local backup creation, WAL delivery, file integrity,
and persistence across container recreation. They do not yet demonstrate
restoration from those backups. Disk loss, crash recovery, off-host restoration,
replication, and failover remain outside the verified boundary.

SQL exercises use the bootstrap administrator over the local container socket.
Application roles and remote authentication are not yet covered. Compose file
secrets are local files rather than an encrypted secret manager.
