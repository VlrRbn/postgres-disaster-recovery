# Optional pgAdmin Acceptance Evidence

- Result: PASS
- Date: `2026-10-01`
- Source: working changes on `feat/pgadmin-ui`, based on `9978c93`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- pgAdmin: `9.18`
- Image index digest: `sha256:c332c5f6dfba995d9ebc4af261d93506d6876085d712eaaa3defc8dd1a3f26de`

## Validation

`make check`, `make pgadmin-acceptance`, and `make acceptance` passed locally.
The workflow YAML parsed successfully. GitHub CI has not yet run for these changes.

## Interface Results

The UI scenario created a disposable project with separate generated passwords
and a random loopback port. Normal `make up` started no pgAdmin container.
`make pgadmin-up` started the interface and passed its HTTP health check.

Docker inspection confirmed the actual web-port binding used `127.0.0.1`, while
PostgreSQL had no published ports and joined only its internal network. The
pgAdmin container mounted neither the source data directory nor the repository.

An HTTP client fetched the React login page configuration, submitted its CSRF
token and generated password with a cookie session, and reached `/browser/`.
This checks the login protocol, not visual rendering of the browser UI.
An authenticated TCP connection from the pgAdmin container queried the empty
primary `orders` table successfully.

## Persistence And Shutdown

`make pgadmin-down` removed only the interface container and left PostgreSQL
running. After `make pgadmin-up`, the generated login secret's checksum was
unchanged, and SQLite inspection confirmed the retained primary server
registration with host `postgres`, port `5432`, database `orders`, and username
`postgres`. Inspection of PID 1 confirmed the application ran as UID 5050.

`make down` removed all active project containers and networks while retaining
the pgAdmin volume. The test cleanup then removed its database, repository, and
UI volumes and temporary secrets. Images and build cache remain local.

## Recovery Regression

The separate recovery acceptance run passed existing persistence, backup,
corruption, missing-WAL, occupied-target, physical restore, and PITR checks.
PITR recovered all 22 expected records before deletion, excluded the later
transaction, and retained recovered-side writes across restart.

## Scope

This is an optional administrative interface for the local primary database.
The recovered instance remains offline from networks. See
[pgAdmin operations](../docs/pgadmin.md) for startup, credentials, SQL, and cleanup.
