# PostgreSQL Disaster Recovery

A PostgreSQL recovery lab built in small, verifiable milestones. The implemented
local foundation combines a digest-pinned database image, persistent storage,
validated order data, and a repeatable container recreation exercise.

## Project Status

The **Local PostgreSQL Foundation** is complete locally. The acceptance path
verifies data persistence and continued writes on a single Docker host:

```text
empty database volume
  -> PostgreSQL initialization and readiness
  -> validated order records
  -> container recreation with the same volume
  -> exact record comparison and successful new writes
```

Backup restoration, point-in-time recovery, and RPO/RTO measurement remain
planned. The first release target is `v0.1.0`; publication follows PR merge and
successful CI on `main`.

## Local PostgreSQL Foundation

Docker Compose runs PostgreSQL 17.11 from the official Debian Bookworm image,
pinned to a multi-platform digest. A named volume stores the database files.
Initialization enables data page checksums and creates the `orders` table.

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
in [acceptance evidence](evidence/local-foundation-acceptance-20260924.md).

## Security Defaults

- official PostgreSQL image pinned to an immutable digest;
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
Bash
Python 3
Make
Git
ShellCheck
```

The first run downloads the pinned PostgreSQL image.

## Run The Local Foundation

Run checks first:

```bash
make check
```

Run the complete disposable acceptance path:

```bash
make acceptance
```

For an interactive database, generate the local password and start PostgreSQL:

```bash
make up
make psql
```

Insert and inspect an order, then exit `psql`:

```sql
INSERT INTO orders (reference, amount_cents) VALUES ('demo-001', 1250);
SELECT * FROM orders;
\q
```

Stop and recreate the interactive database container:

```bash
make down
make up
make psql
```

Run `SELECT * FROM orders;` again to inspect the retained row. Use a new reference
for each additional order. Exit `psql` with `\q`, then run `make down` to stop the
lab. The named database volume remains available for the next session.

## Capability Status

| Capability | Status |
| --- | --- |
| Local PostgreSQL deployment | Complete locally |
| Container recreation and data comparison | Complete locally |
| Pull-request CI | Configured; remote execution pending |
| Physical backup and WAL archiving | Planned |
| Point-in-time recovery | Planned |
| RPO/RTO measurement | Planned |

See the [delivery roadmap](docs/roadmap.md) for milestone scope,
[contribution guidelines](CONTRIBUTING.md) for the PR workflow, and
[release procedure](docs/releasing.md) for publishing verified milestones.

## Safety Boundary

The interactive lab uses Compose project `postgres-dr-local` by default.
`make acceptance` creates its own temporary project, password, and data volume.
Its exit handler removes those test resources; if cleanup fails, it reports the
project and retained secret path for manual inspection. It does not use the
interactive lab's database volume.

`make down` retains the interactive volume. Initialization SQL runs only when
the volume is empty, so editing the SQL file does not migrate an existing database.
Repeating password setup preserves the local file and does not rotate the
password in an initialized database.

## Production Boundaries

This repository currently verifies persistence across a graceful container
recreation on one Docker host. That host is a single failure domain, and its
named volume is not a backup. Disk loss, crash recovery, off-host restoration,
replication, and failover remain outside the verified boundary.

SQL exercises use the bootstrap administrator over the local container socket.
Application roles and remote authentication are not yet covered. Compose file
secrets are local files rather than an encrypted secret manager.
