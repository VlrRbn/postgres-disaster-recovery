# TLS For Streaming Replication

The local replication runtime requires TLS and SCRAM for network replication.
Each Compose service has its own server identity, signed by a private CA for that
runtime. Both `pg_basebackup` and the WAL receiver use `sslmode=verify-full` to
verify the CA chain and the upstream service name.

This extends the existing two-node runtime, including controlled switchover,
offline `pg_rewind`, and role-aware restart. It does not create a new topology.

## Start And Inspect

Run from the repository root:

```bash
make replication-up
make replication-status
```

Startup generates or preserves passwords and TLS files automatically. No manual
`.local` setup is required. To generate or validate only the TLS material:

```bash
make replication-tls-setup
```

OpenSSL is required on the host. The TLS files live under
`${PGDR_REPLICATION_DIR:-./.local/replication}/tls/`:

| File | Purpose | Mounted In Containers |
| --- | --- | --- |
| `ca.crt` | Trusted root certificate | Both services |
| `ca.key` | Private signing key | Neither service |
| `primary.crt`, `primary.key` | Certificate and private key for DNS name `primary` | Service `primary` only |
| `standby.crt`, `standby.key` | Certificate and private key for DNS name `standby` | Service `standby` only |

All generated files have mode `0600`, and the TLS directory has mode `0700`.
They are ignored by Git. Setup preserves complete, valid material and refuses
partial sets, mismatched keys, exposed private keys, invalid trust chains, or
certificates that do not match their service names. Existing files are not
silently overwritten or regenerated.

Each container copies only its own key, certificate, and the CA certificate to
`/var/lib/postgresql/tls/`. The runtime key belongs to PostgreSQL with mode `0600`.
These files are outside `PGDATA`, so base backups and rewind do not copy one
node's server identity onto the other node.

Inspect a public node certificate without printing private keys:

```bash
openssl x509 -in "${PGDR_REPLICATION_DIR:-./.local/replication}/tls/primary.crt" \
  -noout -subject -issuer -dates -ext subjectAltName
```

## Verify Encryption And Identity

`make replication-status` adds TLS, protocol, and cipher columns to the WAL sender
table. A connected receiver should show `TLS=t` with `TLSv1.2` or `TLSv1.3`.
The WAL receiver table also shows whether its connection is configured to verify
the server identity. No rows means no replication connection was observed.

For a direct view before switchover:

```bash
make replication-psql
```

```sql
SELECT r.application_name, r.state, s.ssl, s.version, s.cipher
FROM pg_stat_replication AS r
JOIN pg_stat_ssl AS s USING (pid);
SHOW ssl;
SHOW ssl_min_protocol_version;
SHOW hba_file;
\q
```

TLS is enabled with a minimum protocol version of `TLSv1.2`. The managed HBA file
allows the `replicator` role to use physical replication over TLS from the
connected network with SCRAM authentication. Other network connections,
including plaintext replication, are rejected. SQL administration continues
through the local Unix socket using the existing Make commands; this runtime
does not expose application SQL access over TCP or publish host ports.

The managed HBA file is `/var/lib/postgresql/tls/pg_hba.conf`. The original
`PGDATA/pg_hba.conf` is retained but is not used by these server startup commands.
This also applies to existing and rewound data volumes.

## Existing Volumes And Role Changes

For an existing project, stop its containers and start it with the updated files:

```bash
make replication-down
make replication-up
make replication-status
```

Shutdown preserves both database volumes and the control volume. Startup updates
the recovery connection on a seeded standby, replacing legacy `sslmode=disable`
with `verify-full` and the runtime CA path. It does not reseed the database or
rotate the replication role password. Partial or inconsistent database targets
still fail the existing startup guards.

Certificates identify Compose services, independently of their current database
roles:

| Topology | Receiver | Upstream Name Verified |
| --- | --- | --- |
| Initial | Service `standby` | `primary` |
| After switchover and rejoin | Service `primary` | `standby` |

The rejoin command writes the verified connection to `standby` after offline
rewind. Both services keep their own server key and certificate when roles
change. See [controlled switchover](controlled-switchover.md) for writer pauses,
fencing, and rejoin constraints.

## Expiry And Deliberate Replacement

The generated CA is valid for 365 days and node certificates for 90 days. Setup
checks current certificate validity before startup. It does not renew files in
the background or rotate trust on running connections.

For a deliberate replacement of the complete local CA/certificate set, use the
following example for the default secrets directory. This causes an outage of
both nodes and retains the old material in a private backup directory:

```bash
make replication-down
tls_backup=".local/replication/tls-previous-$(date -u +%Y%m%dT%H%M%SZ)"
mv -T -- .local/replication/tls "$tls_backup"
make replication-up
make replication-status
```

Adjust the paths when using `PGDR_REPLICATION_DIR`. Keep the old directory private;
it contains signing and server keys. Do not replace individual keys independently
or delete database/control volumes to repair a certificate problem. Startup must
validate the complete replacement set and recreate the containers so both nodes
use the same new trust root. The replacement procedure is an operator action,
not a zero-downtime rotation guarantee.

## Acceptance And Stop

```bash
make check
make replication-acceptance
```

The existing disposable scenario verifies:

- encrypted streaming with CA/hostname verification;
- rejection of plaintext, an untrusted root, and a mismatched server name;
- private key permissions and absence of the CA signing key or peer key in each
  container's mounts;
- upgrading legacy standby connection settings while retaining its data;
- outage catch-up and container recreation;
- controlled promotion, fencing, offline rejoin, and verified TLS in the reverse
  direction with 24 exact matching orders.

All Docker tests use a separate temporary project and remove only its resources.
Certificate setup tests use temporary directories without Docker or user secrets.
The [TLS evidence](../evidence/replication-tls-acceptance-20261028.md) records the
completed checks and their boundaries.

Stop the interactive project with:

```bash
make replication-down
```

Certificates, passwords, data, and control state remain. `make stop-all` also
stops the other running project containers from this checkout while retaining
their data.

## Scope

This is a locally generated CA and password-authenticated TLS, not mutual client
certificate authentication. Both nodes still share a Docker
host. Automatic renewal, revocation distribution, multi-host deployment, and
distributed fencing are outside this milestone. TLS does not change asynchronous
replication's data-loss boundary or replace backup/PITR.

## References

- [PostgreSQL server TLS setup](https://www.postgresql.org/docs/17/ssl-tcp.html)
- [Client certificate verification and verify-full](https://www.postgresql.org/docs/17/libpq-ssl.html)
- [Host authentication rules](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)
