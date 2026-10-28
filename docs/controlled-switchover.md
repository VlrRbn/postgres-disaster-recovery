# Controlled Switchover And Rejoin

Move the writable role from the original primary to its standby, then return the
old primary as a read-only replica using offline `pg_rewind`. This procedure uses
the existing local replication project. No AWS resources or new database volumes
are required. A separate `replication_control` volume preserves startup guards.

## Preconditions

- Start with `make replication-up` and inspect `make replication-status`.
- Both nodes must be available, with the original primary writable and the
  standby in recovery. WAL replay must not be paused.
- Stop application writers and finish open write transactions before promotion.
  Keep writers stopped until the new primary is confirmed writable. The command
  captures a WAL position; it does not drain external clients or lock out SQL
  sessions that an operator opens separately.
- Use the existing checksummed PostgreSQL data. Offline rewind requires cleanly
  stopped source and target clusters, a shared cluster identity, suitable WAL
  history, data checksums or `wal_log_hints`, and `full_page_writes` enabled.
- Pause clients again for rejoin: this implementation briefly stops the new
  primary to read its data directory consistently.

The command performs a controlled switchover while the original primary is
reachable. It does not offer forced promotion of an unavailable source or a
zero-loss guarantee during an uncontrolled failure.

## Switch The Writable Role

With writers stopped, run from the repository root:

```bash
make replication-switchover
make replication-status
make replication-primary-psql
```

The command captures the original primary's flushed WAL position and waits up
to 60 seconds for standby replay. It saves that position, fences the old primary,
stops its container, and checks Docker reports it stopped. Only then does it
request `pg_promote(true, 60)`. A physical slot named `primary` is prepared on
the new primary for the returning node.

In SQL, verify the new role and a new write:

```sql
SELECT pg_is_in_recovery(); -- false
INSERT INTO orders (reference, amount_cents)
VALUES ('after-controlled-promotion', 3500)
RETURNING *;
\q
```

Use a new reference when repeating an insert. The service names remain stable
while their PostgreSQL roles change:

| Stage | Compose Service `primary` | Compose Service `standby` |
| --- | --- | --- |
| Initial replication | Writable primary | Read-only standby |
| After promotion | Stopped and fenced | Writable primary |
| After rejoin | Read-only standby | Writable primary |

`make replication-primary-psql` connects to the unique running writable node;
`make replication-standby-psql` connects to the unique running node in recovery. Each refuses
an ambiguous or missing role. `make replication-status` reports the observed role
of each service, including stopped nodes. There is no application proxy or stable
network endpoint that automatically follows the writable role.

## Rejoin The Old Primary

Stop application writers again, then run:

```bash
make replication-rejoin
make replication-status
make replication-standby-psql
```

Rejoin requires the promoted node to be running and writable and the original
primary to be stopped. It checkpoints and cleanly stops the new primary, mounts
its volume read-only in a one-off container, and runs `pg_rewind --dry-run`
followed by the actual rewind of the old primary's volume. Both data directories
are offline throughout the rewind.

The command writes `standby.signal` and connection settings pointing to service
`standby`, using the `primary` slot and the existing private replication password
file. The connection uses `sslmode=verify-full` with the runtime CA to verify
service `standby`; node certificates remain separate from rewound data. It restarts
the new primary, enables startup of the rewound node, and waits for that node to
replay a captured WAL position. See [replication TLS](replication-tls.md).

```sql
SELECT pg_is_in_recovery(); -- true
SHOW primary_slot_name;    -- primary
SELECT * FROM orders WHERE reference = 'after-controlled-promotion';
\q
```

Rewind changes the old primary's data to follow the new primary. It does not merge
two independent write histories. Required old WAL must still be available; no
automatic fresh base backup or volume deletion is attempted on failure.

With a clean controlled switchover, `pg_rewind` can report `no rewind required`:
the old primary has no changes after the divergence point. The command still
checks the histories and prepares standby recovery. The completed acceptance run
exercised this path; copying changed blocks from a genuinely divergent old primary
is not established by that result.

## Stop And Resume

```bash
make replication-down
make replication-up
make replication-status
```

Shutdown retains both database volumes and `replication_control`. Startup reads
the saved transition state. After promotion it starts only service `standby`;
after rejoin it starts that writable node first and the read-only service
`primary` afterwards. Neither role reverts merely because containers are recreated.

The initial Compose dependency still describes first-time seeding. Use the Make
commands for topology-aware startup after promotion. Direct Compose startup of
the fenced old primary fails until rejoin has completed.

## Guards And Interrupted Commands

The shared control volume stores `primary-fenced`, the saved `promotion-target`,
`standby-promoted`, and finally `primary-rejoined`. These survive container
recreation independently of either data directory, including modifications made
by `pg_rewind`. Do not delete this volume or edit its files during recovery.

Topology commands use a nonblocking `flock` in `.local/replication-locks/` to
serialize operations from this checkout. Use one operator and the same checkout;
this lock does not coordinate different hosts or independent checkouts.

- Paused WAL replay or a missing required node rejects promotion before fencing.
- If interruption occurs after fencing but before promotion completes, the old
  primary stays blocked on startup. Inspect status and rerun
  `make replication-switchover` with the standby running to use the saved target.
- If the standby is already writable, promotion refuses to repeat. Continue with
  rejoin after checking status and the fence.
- If rewind fails, the command attempts to resume the new primary and leaves
  the original primary fenced. Inspect logs and target data before attempting
  recovery. A failed rewind can leave the target unusable; do not start it as
  primary or remove its fence. `make replication-up` resumes the promoted node.
- A completed role reversal cannot be switched back by these commands. Repeated
  promotion and repeated rejoin are rejected.

These guards prevent ordinary accidental startup in this single-host runtime.
They are not distributed fencing or a security boundary against a Docker
administrator. Automatic failure detection, forced failover, external fencing,
traffic routing, reverse switchover, and automatic reseeding are outside scope.

## Acceptance

```bash
make check
make replication-acceptance
```

The existing disposable replication scenario first repeats the streaming and
outage checks. It then rejects premature rejoin and paused-replay promotion,
switches roles, verifies a new timeline and writable promoted node, and requires
direct startup of the old primary to fail. Promotion state and a new write must
survive full container removal and startup.

Offline rewind then rejoins the original primary, which must reject writes.
Both nodes must contain 24 byte-for-byte matching orders after reversed streaming
and another recreation. The SQL commands must select the current roles, and
repeated promotion must fail. Cleanup removes all three disposable volumes.

See [switchover evidence](../evidence/controlled-switchover-acceptance-20261016.md)
for the observed results and validation boundaries.

See PostgreSQL's [failover considerations](https://www.postgresql.org/docs/17/warm-standby-failover.html)
and [pg_rewind requirements](https://www.postgresql.org/docs/17/app-pgrewind.html).
