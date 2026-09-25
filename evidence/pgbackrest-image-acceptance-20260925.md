# PostgreSQL Image With pgBackRest Acceptance Evidence

- Result: PASS
- Date: `2026-09-25`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `v5.0.2`
- PostgreSQL: `17.11` (Debian `17.11-1.pgdg12+2`)
- pgBackRest: `2.59.1` (PGDG package `2.59.1-1.pgdg12+1`)
- Tested local image ID: `sha256:45bfd3e94cd2a229f8c4a2c024ef57a644b21adcd669d6911db1c5c5d16d0d40`

## Image Build

`make acceptance` built the image from the pinned PostgreSQL base and executed
the package installation layer. APT added pgBackRest and `libssh2-1`; it reported
zero package upgrades. Build assertions verified that the PostgreSQL version
remained unchanged and that pgBackRest reported `2.59.1`.

A separate `make image` run also passed using the cached installation layer.
The local image ID above identifies the image used by the database acceptance
run, rather than a published registry artifact or a reproducibility guarantee.

## Runtime Verification

The database started on a fresh test volume. SQL reported server version number
`170011`, and `pgbackrest version` executed successfully as the `postgres` user
with output `pgBackRest 2.59.1`.

The existing persistence exercise also passed:

- data checksums were enabled;
- 20 orders were inserted;
- a negative amount was rejected with SQLSTATE `23514`;
- container recreation produced a different container ID;
- ordered CSV snapshots matched for every stored field;
- a new insert succeeded, bringing the order count to 21;
- the temporary container, network, and volume were removed.

The scenario reported:

```text
PASS: PostgreSQL 17.11 and pgBackRest 2.59.1 verified as postgres.
PASS: 20 complete records survived container recreation; new writes succeed; amount constraint and data checksums verified.
```

## Static Validation

`make check` passed Bash syntax, ShellCheck, Compose configuration, and diff
whitespace checks. Both Compose and workflow YAML parsed successfully.

## Scope And Interpretation

This is local evidence for package installation and database compatibility on
amd64. GitHub CI for this change remains pending. The run does not configure or
verify a backup repository, WAL archiving, backup restoration, or PITR.
Transitive APT dependencies remain unpinned, as described in the
[image contract](../docs/pgbackrest-image.md).
