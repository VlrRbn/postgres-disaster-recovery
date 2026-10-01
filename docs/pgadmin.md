# Optional pgAdmin Interface

pgAdmin provides a browser interface for the primary `orders` database. It is
an optional Compose service in the `tools` profile, using the official pgAdmin
9.18 image pinned by digest. Normal `make up` does not start the interface.

## Start And Sign In

From the repository root:

```bash
make pgadmin-up
```

This starts the primary database, checks its backup repository, generates a
separate pgAdmin password if missing, and waits for the interface to respond.
Open <http://127.0.0.1:5050> on the Docker host.

- Login email: `admin@example.com` (a local account; no email delivery is used).
- Login password: the contents of `.local/pgadmin_password`.

Read the password in your own terminal:

```bash
cat .local/pgadmin_password
```

This password signs in to pgAdmin. To connect to PostgreSQL, expand **Servers →
Local lab → Orders — primary** and enter the separate database password:

```bash
cat .local/postgres_password
```

The server definition is imported automatically on first startup. It uses host
`postgres`, port `5432`, database `orders`, and username `postgres`. Choose whether
to save the database password in pgAdmin. Generated passwords are ignored by Git;
do not put their output in evidence or screenshots.

## Inspect Tables And Run SQL

Open **Databases → orders → Schemas → public → Tables → orders**.
Right-click the table and select **View/Edit Data → All Rows** to inspect rows.
Select the database and open **Tools → Query Tool** for SQL:

```sql
SELECT id, reference, amount_cents, created_at FROM public.orders ORDER BY id;
```

This is an administrative connection to the primary database. Changes made in
the grid or Query Tool change its actual data. Use the documented `make backup`
and restore commands for the recovery exercises.

## Stop, Resume, And Logs

Stop and remove only the interface container, keeping the primary running:

```bash
make pgadmin-down
```

Resume it with `make pgadmin-up`. Its account, server registration, preferences,
and any saved database passwords are retained in `pgadmin_data`.

```bash
bash scripts/compose.sh --profile tools ps
bash scripts/compose.sh logs --follow pgadmin
```

`Ctrl+C` exits log following. `make down` stops all project services, including
pgAdmin, and retains all volumes and password files.

## Port And Remote Docker Hosts

If port 5050 is occupied, select another loopback port on every startup:

```bash
PGADMIN_PORT=5051 make pgadmin-up
```

Then open <http://127.0.0.1:5051>. The UI is bound to `127.0.0.1`; PostgreSQL
still has no published host port. If Docker runs on a separate machine, use SSH
forwarding from your workstation (replace the host name):

```bash
ssh -N -L 5050:127.0.0.1:5050 user@docker-host
```

Open the local address while the SSH session is running. The recovered database
keeps `network_mode: none` and is accessed with `make restore-psql`.

## Credentials And Reset

The pgAdmin secret is a separate file with mode `0600`. The official entrypoint
starts as root to read that file and initialize the volume, then runs pgAdmin
as UID 5050. The container has no source data or backup repository mounts.
It joins the internal database network and a separate bridge for the loopback
web port. PostgreSQL joins only the internal network; the recovered service
joins neither. The UI bridge permits outbound traffic from pgAdmin.

Setup preserves existing files. Changing the password file does not reset an
account already stored in `pgadmin_data`; use the UI to change the password.
If you intentionally want to discard all pgAdmin accounts, preferences, saved
passwords, and server registrations in the default project:

```bash
make pgadmin-down
docker volume rm postgres-dr-local_pgadmin_data
make pgadmin-up
```

This recreates the initial account from `.local/pgadmin_password` and imports
`pgadmin/servers.json`. It leaves PostgreSQL data and backups intact. With a
custom `PGDR_PROJECT`, substitute that project's exact UI volume name.

## Acceptance

```bash
make check
make pgadmin-acceptance
```

The UI test uses its own project, generated passwords, and a random loopback
port. It verifies opt-in startup, browser login with CSRF and cookies, an
authenticated SQL connection from the UI container, non-root application
execution, persistence across recreation, and shutdown behavior. It removes its
own containers and volumes on exit. `make acceptance` separately checks backup,
physical restore, and PITR.

## References

Local results: [pgAdmin acceptance evidence](../evidence/pgadmin-acceptance-20261001.md).

- [Official pgAdmin container deployment](https://www.pgadmin.org/docs/pgadmin4/9.18/container_deployment.html)
