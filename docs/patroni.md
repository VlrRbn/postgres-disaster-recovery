# Patroni Automatic Failover

This runtime runs two PostgreSQL nodes managed by Patroni, three etcd members,
and HAProxy as a shared SQL endpoint.
Patroni keeps its leader lease in etcd, promotes an eligible replica after leader
failure, and returns the former leader to replication when it rejoins.

## Start And Inspect

Run from the repository root:

```bash
make patroni-up
make patroni-status
```

Use `make patroni-setup` to prepare or validate credentials and certificates without
starting services. `patroni-up` includes this setup automatically.

The default Compose project is `postgres-dr-patroni`. Passwords and a private CA with
node/client certificates are generated under `.local/patroni/`. Setup preserves valid
existing files and rejects incomplete or invalid certificate sets. Password and
TLS files have mode `0600`; the TLS directory has mode `0700`. The CA lasts
365 days and leaf certificates 90 days. Renewal is manual.

Setup adds `haproxy` to the PostgreSQL certificates when missing, using the existing
CA and node keys. It prepares and verifies both replacements before installing them.
Other identities and credentials remain unchanged. Restarting the containers loads
the updated certificates; database and etcd volumes are retained.

For another independent runtime, set both variables in the same terminal:

```bash
export PGDR_PATRONI_PROJECT=postgres-dr-patroni-demo
export PGDR_PATRONI_DIR="$PWD/.local/patroni-demo"
export PGDR_PATRONI_PORT=16432
make patroni-up
```

Choose an unused host port when running several projects. The default is
`127.0.0.1:6432`; PostgreSQL and etcd do not publish host ports.

Each project has two database volumes, three etcd stores, a shared local backup
repository, and a separate restore volume when recovery is used. It uses
its own data, configuration, and certificates. The existing manual replication
and local/S3 backup commands target separate PostgreSQL clusters. Use the
`patroni-backup-*` and `patroni-restore-*` commands for this runtime; see
[Patroni backup and recovery](patroni-recovery.md).
An optional [S3 backend](patroni-s3-recovery.md) uses the same commands with a
separate project and repository prefix; the local backend remains the default.

`patroni-status` should show one `Leader` and one `Replica` in state `streaming`.
Either `pg1` or `pg2` can become leader. The three etcd members need a majority
of two for leader coordination.

## Write And Read

```bash
make patroni-primary-psql
```

```sql
INSERT INTO orders (reference, amount_cents)
VALUES ('patroni-demo-001', 1500);
\q
```

Read from the current replica:

```bash
make patroni-standby-psql
```

```sql
SELECT id, reference, amount_cents FROM orders ORDER BY id;
SELECT pg_is_in_recovery();
\q
```

SQL helpers inspect verified HTTPS role endpoints and open a local socket on the
selected node. The primary endpoint requires the primary role and Patroni leader
lock. Unknown API results or ambiguous roles reject the connection. Selection
happens when the command starts; an existing SQL connection is not moved to
another node during failover.

## Connect Through HAProxy

Use the shared address without selecting a PostgreSQL member:

```bash
make patroni-endpoint-psql
```

```sql
SELECT pg_is_in_recovery();
SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();

INSERT INTO orders (reference, amount_cents)
VALUES ('patroni-endpoint-001', 3500)
RETURNING id, reference, amount_cents;
\q
```

The command starts a disposable `psql` client and connects to `haproxy:5432`
with `sslmode=verify-full`. It uses a temporary private password file, mounts
only the database password and CA certificate, and removes the client after
exit. SQL history is not saved to disk in this disposable client. It does not
inspect roles or connect directly to a selected node.
The existing `patroni-primary-psql` and `patroni-standby-psql` commands remain
available for administration through node-local sockets.

HAProxy forwards TCP traffic unchanged. PostgreSQL presents its own certificate;
both node certificates include the shared `haproxy` DNS identity. Separate HTTPS
checks to each Patroni `/primary` endpoint verify the CA and the individual
node name. Only a `200` response admits that node. Backends start unavailable
and require two successful checks; checks run every second with two failures
marking a backend down. DNS resolution follows Docker service names.

From an installed host `psql`, use the published loopback address:

```bash
PGSSLMODE=verify-full \
PGSSLROOTCERT="${PGDR_PATRONI_DIR:-$PWD/.local/patroni}/tls/ca.crt" \
psql -h 127.0.0.1 -p "${PGDR_PATRONI_PORT:-6432}" -U postgres -d orders -W
```

Enter the password from the runtime's `postgres_password` file. The certificates
also cover `127.0.0.1`. The SQL helper authenticates as `postgres` for
administration; application-specific roles are not provisioned here.

An open SQL session is disconnected when its backend fails or is marked down.
Reconnect through the same endpoint after failover. HAProxy does not replay
transactions, retry writes, or resolve an unknown commit outcome. Idle sessions
time out after one hour. One HAProxy container and one Docker host remain
shared failure points.

## Image Versions

The PostgreSQL `17.11` base and etcd `3.6.5` image are pinned by multi-platform
digest. The Patroni image pins Patroni `4.1.5` and `psycopg2-binary` `2.9.11` and checks
that building did not change the PostgreSQL version. Transitive Python and APT
dependencies resolve from live repositories; byte-identical rebuilds are not
guaranteed. Only the Dockerfile enters the image build context. HAProxy
`3.2.26-alpine` is also pinned by its multi-platform digest. The Patroni image
includes the same pgBackRest `2.59.1` package as the standalone backup runtime.

## Stop A Leader And Observe Failover

Check `make patroni-status` first. This example assumes `pg1` is leader; substitute
`pg2` if needed. Stop application writes before a deliberate experiment.

```bash
bash scripts/compose.sh --patroni kill --signal SIGKILL pg1
make patroni-status
```

Election follows lease expiration and health checks. Bootstrap settings are
`ttl=20`, `loop_wait=5`, and `retry_timeout=5` seconds. Observe the surviving node
becoming leader, then use `make patroni-primary-psql` to write to it. These settings
do not establish a recovery-time guarantee.

Restart the failed container:

```bash
bash scripts/compose.sh --patroni start pg1
make patroni-status
```

Patroni uses `pg_rewind` for a diverged former leader when the required history
is available. Automatic deletion after rewind failure or timeline divergence is
disabled. If recovery fails, inspect logs and retained data before replacement.
The manual runtime's `replication-rejoin` and `replication-reseed` commands are
not used for Patroni-managed data.

To verify application routing, write through `make patroni-endpoint-psql`
before the crash, then open the same command again after promotion. The client
address stays `haproxy:5432` even when the PostgreSQL leader changes. An existing
session must reconnect.

## Quorum And Transport Security

Losing one etcd member leaves a majority of two. Losing two removes quorum.
With `failsafe_mode=false`, the primary demotes when it cannot renew its lease;
writes remain unavailable until coordination and a suitable leader recover.

etcd client and peer traffic require CA-verified mutual TLS. Each member mounts
its own key. Patroni nodes mount their own server key and a shared etcd client
identity; the CA signing key stays on the host. Transport authentication protects
this dedicated etcd cluster; per-prefix etcd RBAC is not configured.

PostgreSQL replication and rewind use `sslmode=verify-full`. HBA rules require
SCRAM over TLS for network connections and reject plaintext. Patroni REST uses
HTTPS, with Basic authentication for configuration-changing requests. Private
configuration files hold credentials; password values are not passed in container
environment variables. Only HAProxy publishes a host port, bound to loopback.
An additional bridge network supports that publication; only HAProxy joins it.
PostgreSQL and etcd stay on the internal `patroni` network. HAProxy mounts only
the public CA certificate, with no PostgreSQL passwords or private keys.

The HAProxy Compose health check validates its configuration. A healthy proxy
container can still have no eligible primary; a SQL connection checks actual
write-route availability. During majority loss the endpoint rejects connections
until a confirmed primary becomes available again.

Fresh clusters also enable pgBackRest WAL archiving. For a cluster created
before `v0.15.0`, follow the explicit DCS configuration and restart steps in
[backup setup](patroni-recovery.md#upgrade-an-existing-cluster). Backup commands
select the current primary; restore uses a separate, isolated PostgreSQL process.

All components share one Docker host. Watchdog devices and external host fencing
are not configured. Container/DCS checks do not prove safety under a suspended
Patroni process, kernel failure, or host loss. Asynchronous replication can lose
acknowledged writes. `maximum_lag_on_failover` is a byte-based eligibility setting,
not a zero-loss or time-based guarantee.

## Logs And Shutdown

```bash
bash scripts/compose.sh --patroni logs --follow --tail 50
make patroni-down
```

`patroni-down` removes live and restore containers and both networks, retaining
database, etcd, backup, and restore volumes, passwords, and certificates.
`patroni-up` resumes the live cluster; `patroni-restore-up` resumes the separate
recovered database. Bootstrap DCS settings only apply when the cluster is first created;
change existing cluster settings through Patroni. `make stop-all` also stops this
checkout's Patroni containers while retaining state.

## Acceptance

```bash
make check
make patroni-acceptance
```

The disposable scenario checks replication, read-only enforcement, verified TLS,
REST authentication, certificate mounts, automatic failover, former-leader
recovery, single-member etcd loss, majority loss/restoration, and recreation.
All 25 workload inserts go through HAProxy. It also verifies client rejection
of plaintext, wrong server identity, and untrusted certificates; separate proxy
fixtures reject wrong-CA and wrong-host HTTPS checks.

It confirms that 20 acknowledged orders reached the replica, disconnects that
replica's network, and journals five more successful commits on the primary.
After crashing the primary and reconnecting the replica, it compares the promoted
database with all 25 acknowledgments. The five missing orders are expected in
this intentionally isolated asynchronous case.

The JSON report and acknowledgment journal remain under `.local/reports/`.
The report records both promotion time and the time to the first successful
verified SQL connection through HAProxy. Measurements include replica network
reconnection; the endpoint measurement also includes disposable client startup.
They are observed test results, not recovery guarantees. The scenario checks
that an established session breaks and a new session reaches the promoted node.
Test containers, networks, volumes, and temporary credentials are removed.
Cleanup failure retains the private directory and reports its path.

See [Patroni acceptance evidence](../evidence/patroni-acceptance-20261103.md)
and [HAProxy endpoint evidence](../evidence/patroni-endpoint-acceptance-20261103.md).

## References

- [Patroni configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [Patroni replication modes](https://patroni.readthedocs.io/en/latest/replication_modes.html)
- [Patroni watchdog limits](https://patroni.readthedocs.io/en/latest/watchdog.html)
- [etcd transport security](https://etcd.io/docs/v3.6/op-guide/security/)
- [Patroni role endpoints](https://patroni.readthedocs.io/en/latest/rest_api.html)
- [HAProxy configuration](https://docs.haproxy.org/3.2/configuration.html)
