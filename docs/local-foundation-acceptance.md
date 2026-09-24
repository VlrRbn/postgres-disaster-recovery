# Local PostgreSQL Foundation Acceptance Criteria

The foundation is complete when all of the following are demonstrated locally:

- The database starts from the reviewed image pinned to an immutable digest.
- A fresh volume initializes with data page checksums enabled.
- PostgreSQL becomes ready within the startup deadline.
- The acceptance workload inserts exactly 20 orders.
- A negative amount is rejected with SQLSTATE `23514`.
- Container recreation produces a different container ID on the same volume.
- Ordered snapshots of all stored order fields match byte for byte.
- A new insert succeeds after recreation and the total order count becomes 21.
- The test container, network, and volume are removed after the run.
- Repeating local password setup preserves the existing password file.
- The generated local password has mode `0600` and is ignored by Git.

## Acceptance Sequence

Run static checks and the automated database scenario:

```bash
make check
make acceptance
```

`make check` covers Bash syntax, ShellCheck, Compose configuration, and diff
whitespace. `make acceptance` runs the database assertions in an isolated
Compose project and reports a nonzero exit status on failure. Password setup
idempotence, file permissions, and Git exclusion were checked separately in the
recorded local run; they are not assertions in `make acceptance`.

The successful database scenario reports:

```text
PASS: 20 complete records survived container recreation; new writes succeed; amount
constraint and data checksums verified.
```

## Validation And Evidence

The [local acceptance report](../evidence/local-foundation-acceptance-20260924.md)
records the completed foundation run. The script prints its result to the
terminal; it does not generate a persistent Markdown report automatically.
GitHub CI runs the static checks and database scenario for pull requests and
commits on `main`.

## Interpretation

This exercise demonstrates data persistence after a graceful container
recreation and continued writes against the retained database volume. It does
not exercise restoration from backup, point-in-time recovery, disk loss,
crash recovery, or host failure.
