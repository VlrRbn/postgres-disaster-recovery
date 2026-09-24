# Local PostgreSQL Foundation Acceptance Evidence

- Result: PASS
- Date: `2026-09-24`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `v5.0.2`
- Database: PostgreSQL `17.11` (Debian `17.11-1.pgdg12+2`)
- Tested scope: initial Local PostgreSQL Foundation implementation
- Image: `postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652`

## Acceptance Sequence

The scenario initialized a fresh database volume in a separate Compose project:

```text
empty test volume
  -> database initialization and readiness
  -> checksum and order constraint checks
  -> 20 stored orders and an ordered CSV snapshot
  -> replacement container on the same volume
  -> matching snapshot and successful new insert
  -> test resource cleanup
```

## Static Checks

`make check` passed Bash syntax, ShellCheck, Compose configuration, and diff
whitespace checks.

## Persistence Exercise

`make acceptance` verified that data checksums were enabled and inserted 20
orders. PostgreSQL rejected a negative amount with SQLSTATE `23514`.

Container recreation produced a different container ID. The ordered CSV
snapshots of every stored field matched byte for byte before and after
recreation. A new order was inserted successfully, bringing the total to 21.
The test container, network, and volume were removed successfully.

The scenario reported:

```text
PASS: 20 complete records survived container recreation; new writes succeed; amount constraint and data checksums verified.
```

## Local Password Setup

A separate repeated `make setup` check verified that the existing password was
preserved, its file mode was `0600`, and Git ignored the file.

## Scope And Interpretation

This report records the original local validation run, reformatted without a
new database run. It demonstrates persistence across a graceful container
recreation and continued writes using the retained volume. It does not claim
backup restoration, crash recovery, point-in-time recovery, failover, or RPO/RTO
results. GitHub CI execution remains pending and must pass before release.
