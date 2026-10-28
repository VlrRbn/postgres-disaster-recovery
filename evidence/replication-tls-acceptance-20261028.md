# Replication TLS Acceptance Evidence

- Result: PASS
- Date: `2026-10-28`
- Source: working changes on `feat/replication-tls`, based on `88349a3`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Host tools: Python `3.12.3`, OpenSSL `3.0.13`

## Validation

`make replication-acceptance` passed all 11 stages on disposable project
`postgres-dr-replication-test-1793210238-27349`. The scenario repeated streaming,
read-only, outage, persistence, promotion, and rejoin checks with verified TLS.
Additional checks exercised plaintext rejection, trust and hostname validation,
private-key mounts, and recovery connection upgrade on retained data.

| Check | Observed Result |
| --- | --- |
| Seeding and WAL | Standby seeded with verified TLS; all 20 orders matched through asynchronous streaming |
| Replication client | Connection using the runtime CA and `verify-full` succeeded |
| Plaintext | The replication role with `sslmode=disable` rejected with a no-encryption HBA diagnostic |
| Untrusted CA | Connection using an unrelated CA rejected with a certificate verification error |
| Server name | Correct primary address with an incorrect requested hostname rejected with a name-verification error |
| Private keys | Neither node mounted the CA signing key or peer key; runtime server keys had mode `0600` |
| Authentication file | Both nodes used `/var/lib/postgresql/tls/pg_hba.conf` |
| Legacy connection | A stopped seeded standby configured with `sslmode=disable` resumed with verified TLS and retained its data |
| Outages and recreation | Standby catch-up, readable primary outage, unsafe-target rejection, and 22-row persistence passed |
| Promotion guards | Paused-replay promotion and premature rejoin rejected; old-primary fencing persisted |
| Promoted write | New primary accepted a write after controlled promotion |
| Offline rejoin | Both pg_rewind invocations reported `no rewind required`; old primary returned read-only with verified reverse streaming |
| Reversed recreation | Saved roles survived recreation; all 24 rows matched and SQL commands selected the current roles |

Final sender status showed application `primary`, state `streaming`, mode `async`,
zero reported replay lag, TLS `t`, protocol `TLSv1.3`, and cipher
`TLS_AES_256_GCM_SHA384`. The receiver on service `primary` reported
`Verify server identity=t` and used slot `primary`. Negative connection checks
required the specific rejection diagnostic, not just a nonzero result.

Cleanup removed both disposable containers, their network, both data volumes,
the control volume, and the temporary certificate/password directory. The local
topology lock was removed after the completed run. These automated checks did
not change interactive databases or secrets.

A separate walkthrough used the existing `postgres-dr-replication` project with
roles already reversed from a previous switchover. Service `standby` remained
writable, while service `primary` received WAL over TLS 1.3. A replication client
with the runtime CA and `verify-full` succeeded on timeline `2`. Plaintext was
rejected with `no encryption`; an incorrect hostname failed name verification;
the system CA bundle, which does not trust the local CA, failed certificate
verification.

Order `38`, reference `tls-demo-001`, amount `6500`, reached the read-only
replica. After `make replication-down` and `make replication-up`, the row and
reversed roles remained. Status again showed `streaming`, TLS `t`, protocol
`TLSv1.3`, cipher `TLS_AES_256_GCM_SHA384`, zero reported lag, and an active
`primary` slot. The receiver still reported `Verify server identity=t`.

## Regression

`make check` passed shell syntax, ShellCheck, 67 Python test methods, all four
Compose configurations, systemd definitions and calendars, and diff formatting.

Seven new setup tests used temporary directories and the actual OpenSSL CLI.
They verified complete generation with private directory/key permissions,
paths containing spaces, and preservation of existing file contents on repeat
setup. Incomplete material, mismatched keys, a trusted certificate for the wrong
hostname, and group/world-readable keys were rejected. A generation failure
removed its staging directory. These tests did not use Docker or user secrets.

## Interpretation

The result verifies encrypted seeding and WAL streaming, trust/name enforcement,
and retained-data startup through the existing topology transitions. The legacy
connection check simulated the old setting on a seeded test volume. The
walkthrough additionally resumed existing interactive volumes and preserved
their data and reversed roles through recreation.

Certificate expiry and deliberate CA replacement were not separately exercised
against a running cluster. Their procedure requires a restart and does not
establish automatic renewal or zero-downtime rotation. The offline rewind checks
found no changes requiring block copying from a diverged writable old primary.

Both nodes share a Docker host. These checks do not establish multi-host
availability, distributed fencing, or zero-loss recovery with asynchronous
replication. GitHub CI remains pending for these working changes.
