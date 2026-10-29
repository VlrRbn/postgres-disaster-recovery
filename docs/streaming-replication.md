# Local Streaming Replication

Run an asynchronous PostgreSQL primary and one read-only standby on the same
Docker host. The standby is seeded with `pg_basebackup` and then receives WAL
over a replication connection. Both use the existing PostgreSQL 17.11 image.
This runtime is separate from the local backup and AWS S3 environments.

## Start And Inspect

Run from the repository root:

```bash
make replication-up
make replication-status
```

Startup generates two private password files in `.local/replication/`, creates
the primary's `orders` table and replication identity on its first initialization,
and seeds an empty standby volume. Existing passwords and database volumes are
preserved. No AWS credentials or cloud resources are used.

The default Compose project is `postgres-dr-replication`; no override is needed
for normal use. Optional `PGDR_REPLICATION_PROJECT` overrides must retain the
`postgres-dr-replication-` prefix. Use a separate `PGDR_REPLICATION_DIR` for an
independent environment's password files. `PGDR_PROJECT`,
`PGDR_REPOSITORY`, and the backup runtimes' password variables do not select
this environment.

Status labels each Compose service with its current database role and prints
separate blocks for the primary's WAL sender and replication slots, and the
standby's recovery and WAL receiver. Table columns use readable labels such as
`Connection`, `Replay lag (bytes)`, `In use`, and `Last replayed WAL (LSN)`.
A short legend explains the states and absent connections.

Expect `streaming`, `Mode=async`, slot `standby` with `In use=t`, and `In recovery=t`
on the standby. `Replay lag (bytes)` is the difference between the primary's current WAL
position and the standby replay position last reported to the primary. It is
a point-in-time observation; a healthy standby may briefly report a nonzero gap.
Standby container health requires readable recovery mode, so it can remain
healthy while the primary is unavailable. Use replication status to inspect
the connection separately.

## Write And Read

Open the primary:

```bash
make replication-primary-psql
```

```sql
SELECT pg_is_in_recovery(); -- false
INSERT INTO orders (reference, amount_cents) VALUES ('replication-demo-001', 1500);
SELECT pg_current_wal_lsn();
\q
```

Open the standby:

```bash
make replication-standby-psql
```

```sql
SELECT pg_is_in_recovery(); -- true
SHOW transaction_read_only; -- on
SELECT * FROM orders WHERE reference = 'replication-demo-001';
SELECT pg_last_wal_replay_lsn();
INSERT INTO orders (reference, amount_cents) VALUES ('standby-write', 100);
-- ERROR: cannot execute INSERT in a read-only transaction
\q
```

Replication is asynchronous: a successful primary commit does not guarantee
that the row is already readable on the standby. Repeat the SELECT if needed.
Use a new reference when repeating an insert.

## Stop, Resume, And Observe An Outage

Stop and remove both containers and their network while preserving both data
volumes and the control state:

```bash
make replication-down
make replication-up
```

The standby resumes from its own volume. It does not run a new base backup.
For individual services, use the dedicated Compose configuration:

```bash
bash scripts/compose.sh --replication stop standby
make replication-primary-psql
```

```sql
INSERT INTO orders (reference, amount_cents) VALUES ('while-standby-stopped', 2500);
\q
```

```bash
bash scripts/compose.sh --replication up --no-build --detach --wait standby
make replication-status
make replication-standby-psql
```

```sql
SELECT * FROM orders WHERE reference = 'while-standby-stopped';
\q
```

The physical slot retains WAL needed by a disconnected standby, with
`max_slot_wal_keep_size=256MB` to limit retention at checkpoints. The primary
also sets `wal_keep_size=64MB`. These local runtime settings provide no guaranteed
outage duration or exact disk-use ceiling. If required WAL is recycled and the slot
becomes `lost`, an ordinary restart cannot recover the missing history. Use the
[explicit standby reseed](#recover-after-wal-loss) after inspecting the slot and logs.

To stop only the primary and observe the standby's retained readable snapshot:

```bash
bash scripts/compose.sh --replication stop primary
make replication-standby-psql
```

```sql
SELECT * FROM orders ORDER BY id;
SELECT pg_is_in_recovery(); -- remains true
\q
```

Resume the primary, then inspect reconnection:

```bash
bash scripts/compose.sh --replication up --no-build --detach --wait primary
make replication-status
```

The standby stays read-only during this outage procedure. For an explicit role
change, see [controlled switchover and rejoin](controlled-switchover.md).
Stop the services with `make replication-down`
when finished. Named volumes, local secrets, images, and build cache remain.

## Recover After WAL Loss

Run from the repository root. First identify the current roles and slot state:

```bash
make replication-status
bash scripts/compose.sh --replication logs --tail 50 standby
```

In the initial topology, service `primary` is writable and service `standby`
receives WAL. The source slot must be physical, inactive, and `lost`. The standby
log reports that a required WAL segment was removed or its slot was invalidated.
A container can still be healthy and readable while its WAL receiver cannot
reconnect; container health alone does not establish streaming.

After confirming the target, replace the initial standby:

```bash
RESEED_NODE=standby make replication-reseed
make replication-status
make replication-standby-psql
```

```sql
SELECT pg_is_in_recovery(); -- true
SELECT status, slot_name FROM pg_stat_wal_receiver; -- streaming, standby
\q
```

After a completed switchover and rejoin, service `standby` is writable and
service `primary` is the replica. Inspect logs for `primary` and instead use:

```bash
RESEED_NODE=primary make replication-reseed
```

The command rejects a missing or wrong `RESEED_NODE`, a healthy slot, an
unavailable primary, a writable target, unrelated database identities, missing
standby data, additional source tablespaces, and an unfinished role transition.
It uses the existing topology lock and requires the same single operator/checkout
as switchover. It does not recover the fenced original primary before rejoin.

The source stays running. Only the selected replica is stopped. Its lost slot
is recreated, and `pg_basebackup` copies a fresh database through verified TLS
into `.pgdr-reseed` inside that replica's data volume. `pg_verifybackup` checks
the new copy before the old files are replaced. Allow space for the existing
standby plus a complete new base backup and its WAL. The old copy is discarded
after verification. Node keys and the control volume remain separate from copied
database files.

A successful command resumes the selected node read-only, waits for WAL replay,
and prints `Reseed complete`. Check that its slot is active, the sender reports
TLS, and the receiver reports `streaming`. Subsequent writes on the primary
should appear on the standby.

### If Reseeding Is Interrupted

Before the slot is replaced, `reseed-NODE` in the control volume records the
source database identity. Startup refuses to use that node until a complete
verified copy is installed. If copying fails, the previous data stays in place;
an interruption during file replacement can leave partial data, which the marker
also blocks. Fix the reported cause, such as TLS trust or insufficient storage,
then repeat the same `RESEED_NODE=... make replication-reseed` command.

A pending operation can recreate its inactive physical slot even if it is no
longer `lost`, or create it if the previous attempt stopped after dropping it.
It still requires the same source identity and a valid, reachable primary.
Do not remove the marker, edit topology files, or start the target manually.

If the command completed copying and removed the marker but startup was
interrupted, inspect the slot/data and use `make replication-up` to resume.
An already healthy replica is not reseeded again. `make replication-down`
removes containers and the network while retaining databases and control state.

## Authentication And Storage

The dedicated `replicator` role has `LOGIN` and `REPLICATION`, without superuser,
database creation, or role creation privileges. A replication-specific HBA rule
requires TLS and SCRAM authentication from the connected network. Startup copies the
replication secret into a PostgreSQL-owned private file for primary initialization
and into a `0600` password file on the standby. Connection settings reference
that password file; passwords are not embedded in `primary_conninfo`.

The two database services have separate named volumes and an internal Docker
network, with no published host ports. Base backup and WAL streaming require
`sslmode=verify-full`, using a private runtime CA and separate server identities.
TLS files are generated automatically and kept outside the database volumes.
See [replication TLS](replication-tls.md) for trust, expiry, existing-volume startup,
and replacement. Both containers still share a Docker host, so the deployment
has no host-failure tolerance. Archiving is off in this separate runtime.

Streaming also copies accidental deletes and other unwanted committed changes.
Keep the existing backup/PITR workflow for recovery to an earlier state.

The standby entrypoint seeds only an empty target. It refuses a nonempty target
without `PG_VERSION` and `standby.signal` unless the controlled promotion marker
permits startup of the new primary. Existing standby volumes must belong to this primary;
no automatic identity reconciliation or repair is attempted. Changing a password
file does not rotate a role password inside an existing primary.

## Acceptance

```bash
make check
make replication-acceptance
```

The disposable scenario uses a unique project and temporary secrets, then checks:

- verified TLS streaming and rejection of plaintext, an untrusted CA, and a wrong server name;
- legacy connection-setting upgrade without reseeding retained data;
- exact ordered CSV equality for every stored field after WAL replay;
- asynchronous streaming and a restricted replication role;
- rejected standby writes with SQLSTATE `25006`;
- catch-up after a standby outage;
- readable standby during a primary outage and reconnection afterwards;
- rejection of a nonempty target without its standby marker;
- exact 22-row equality after both containers are recreated;
- real slot/WAL loss followed by rejected ordinary restart and explicit reseeding;
- a failed untrusted-CA copy that preserves old standby data, blocks startup, and permits retry;
- target/identity/role guards and verified TLS after reseeding in both topologies;
- no published host ports.

The scenario also verifies controlled promotion, persisted fencing, offline
rewind, and role-aware restart; see the [switchover contract](controlled-switchover.md#acceptance).

Replay waits use WAL positions with a 60-second deadline. Cleanup removes only
the disposable project's containers, network, three volumes, and secrets. Images and
build cache remain. CI runs this scenario alongside the existing recovery checks.

The streaming run is recorded in
[replication evidence](../evidence/streaming-replication-acceptance-20261015.md).
See [standby reseed evidence](../evidence/standby-reseed-acceptance-20261029.md)
for the WAL-loss exercise and its recovery checks.

See PostgreSQL's [streaming replication](https://www.postgresql.org/docs/17/warm-standby.html#STREAMING-REPLICATION),
[pg_basebackup](https://www.postgresql.org/docs/17/app-pgbasebackup.html),
[slot state](https://www.postgresql.org/docs/17/view-pg-replication-slots.html),
and [password file](https://www.postgresql.org/docs/17/libpq-pgpass.html) documentation.
