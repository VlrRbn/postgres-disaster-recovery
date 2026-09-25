# PostgreSQL Image With pgBackRest

This step adds the backup executable to the existing PostgreSQL container and
verifies that the database foundation still works.

## Image Build

The Dockerfile under `docker/postgres/` extends the official PostgreSQL 17.11
Bookworm image pinned by multi-platform digest. It installs the exact PGDG package
`pgbackrest=2.59.1-1.pgdg12+1` without recommended packages, verifies that the
PostgreSQL version did not change, and requires `pgBackRest 2.59.1` output.

The build inherits the official entrypoint and default command. It also creates
`/var/lib/pgbackrest` with owner `postgres` and mode `0750`, which initializes the
permissions of a fresh repository volume. Build context
is limited to `docker/postgres/`, with only the Dockerfile allowed by its
`.dockerignore`. Local credentials and database contents are outside that context.

Build the interactive lab image without starting a database:

```bash
make image
```

`make up` and `make acceptance` also build the image. Compose assigns a local
project-specific image name; no derived image is published to a registry.
The acceptance script recreates the container without rebuilding or pulling
another image during its data comparison.

See [local commands](../README.md#local-commands) for the command summary,
[startup](../README.md#run-the-local-foundation) for an interactive session,
and [image removal](../README.md#remove-the-local-image) for cleanup.
`make image` only builds an image; it does not start a database.

## Version And Dependency Contract

The base image digest and pgBackRest package version are fixed in the Dockerfile.
An unavailable package version fails the build instead of selecting another
release. A PostgreSQL version change or unexpected pgBackRest version also
fails the build.

Transitive package dependencies resolve from the live Debian and PGDG APT
repositories. Their metadata and package hashes are verified by APT, but they
are not pinned to repository snapshots. The resulting image is locally built,
and byte-identical rebuilds are not guaranteed. Existing Docker build cache may
reuse a previously installed dependency set.

## Validation And Evidence

Run the checks and the complete disposable database scenario:

```bash
make check
make acceptance
```

Acceptance checks PostgreSQL `17.11` through SQL and runs `pgbackrest version`
as the container's `postgres` user. It then exercises the existing order
constraint, checksum, container recreation, exact record comparison, and new
write checks.

See [image acceptance evidence](../evidence/pgbackrest-image-acceptance-20260925.md)
for the completed local run. GitHub CI builds the image as part of the same
acceptance command. Its job name remains `Foundation checks`.

## Scope And Interpretation

The tested platform is Linux amd64. Build cache and derived images remain local;
the acceptance exit handler removes the test container, network, and both volumes.

The image supplies pgBackRest and its repository directory. Compose and the
[backup operations](backup-wal-archiving.md) layer configure storage, WAL
archiving, the stanza, and retention. Restoration remains a separate planned
capability.

## References

- [pgBackRest Installation](https://pgbackrest.org/user-guide.html#installation)
- [PostgreSQL APT Repository](https://wiki.postgresql.org/wiki/Apt)
