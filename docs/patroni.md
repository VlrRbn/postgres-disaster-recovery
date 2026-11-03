# Patroni Automatic Failover

This runtime runs two PostgreSQL nodes managed by Patroni and three etcd members.
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

For another independent runtime, set both variables in the same terminal:

```bash
export PGDR_PATRONI_PROJECT=postgres-dr-patroni-demo
export PGDR_PATRONI_DIR="$PWD/.local/patroni-demo"
make patroni-up
```

Each project has five data volumes: two databases and three etcd stores. It uses
its own data, configuration, and certificates. The existing manual replication
and local/S3 backup commands target separate PostgreSQL clusters; they do not
back up or change this Patroni cluster.

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
another node during failover. HAProxy routing is a separate follow-up.

## Image Versions

The PostgreSQL `17.11` base and etcd `3.6.5` image are pinned by multi-platform
digest. The Patroni image pins Patroni `4.1.5` and `psycopg2-binary` `2.9.11` and checks
that building did not change the PostgreSQL version. Transitive Python and APT
dependencies resolve from live repositories; byte-identical rebuilds are not
guaranteed. Only the Dockerfile enters the image build context.

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
environment variables. No service publishes a host port.

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

`patroni-down` removes containers and the network, retaining database/etcd volumes,
passwords, and certificates. `patroni-up` resumes that state. Bootstrap DCS settings
only apply when the cluster is first created; change existing cluster settings
through Patroni. `make stop-all` also stops this checkout's Patroni containers while
retaining state.

## Acceptance

```bash
make check
make patroni-acceptance
```

The disposable scenario checks replication, read-only enforcement, verified TLS,
REST authentication, certificate mounts, automatic failover, former-leader
recovery, single-member etcd loss, majority loss/restoration, and recreation.

It confirms that 20 acknowledged orders reached the replica, disconnects that
replica's network, and journals five more successful commits on the primary.
After crashing the primary and reconnecting the replica, it compares the promoted
database with all 25 acknowledgments. The five missing orders are expected in
this intentionally isolated asynchronous case.

The JSON report and acknowledgment journal remain under `.local/reports/`.
Failover timing runs from leader-container kill to a reachable promoted database,
including reconnection of the isolated replica. It does not measure application
reconnection through a stable endpoint. Test containers, network, volumes, and
temporary credentials are removed. Cleanup failure retains the private directory
and reports its path.

See [Patroni acceptance evidence](../evidence/patroni-acceptance-20261103.md).

## References

- [Patroni configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [Patroni replication modes](https://patroni.readthedocs.io/en/latest/replication_modes.html)
- [Patroni watchdog limits](https://patroni.readthedocs.io/en/latest/watchdog.html)
- [etcd transport security](https://etcd.io/docs/v3.6/op-guide/security/)
