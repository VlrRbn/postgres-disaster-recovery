# Scheduled Backups And Health Checks

Install two optional systemd user timers for the existing local backup runtime.
The backup service creates and verifies a full backup; the health service checks
completed-backup freshness and actively verifies WAL delivery. Both reuse the
existing Make commands through a shared project lock.

## Prerequisites And Scope

Run as the account that owns the checkout and can access Docker without `sudo`.
The host needs systemd with a working user manager, `systemctl`,
`systemd-analyze`, Make, Python, and `flock`. The supported repository is local;
AWS S3 scheduling and the separate replication runtime are outside this step.

The database must already be running with an initialized repository. Scheduled
jobs do not start, stop, or repair PostgreSQL. Prepare the default environment:

```bash
cd ~/postgres-disaster-recovery
make up
make backup
make backup-health
```

## Install Without Enabling Timers

```bash
make schedule-install
```

The installer copies four unit files to
`${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, validates them, and reloads the
user manager. It does not enable or start a timer or run a backup. It creates
`${XDG_CONFIG_HOME:-$HOME/.config}/postgres-dr/schedule.env` with mode `0600`.
Existing configuration is preserved on reinstall; unit files are refreshed.
Use systemd drop-ins for custom unit settings so reinstall does not replace them.

`XDG_CONFIG_HOME` is the user's configuration directory. The Bash expression
`${XDG_CONFIG_HOME:-$HOME/.config}` uses its value when set and nonempty,
otherwise falling back to `$HOME/.config` (usually `/home/USERNAME/.config`).
These are environment variables supplied by the session, not project settings.
Inspect the resolved directory and installed configuration with:

```bash
printf 'Configuration directory: %s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
cat "${XDG_CONFIG_HOME:-$HOME/.config}/postgres-dr/schedule.env"
```

The generated config explicitly selects the checkout, `postgres-dr-local`, its
password file, and local repository mode. It does not inherit those choices
from an interactive shell. Password contents are not copied into this config.

```text
PGDR_ROOT="/absolute/path/to/postgres-disaster-recovery"
PGDR_REPOSITORY="local"
PGDR_PROJECT="postgres-dr-local"
PGDR_SECRET_FILE="/absolute/path/to/postgres-disaster-recovery/.local/postgres_password"
PGDR_S3_FIXTURE="0"
PGDR_BACKUP_MAX_AGE_SECONDS="93600"
PGDR_ARCHIVE_TIMEOUT_SECONDS="10"
PGDR_SCHEDULE_LOCK_TIMEOUT_SECONDS="300"
```

For another existing local project, edit `PGDR_PROJECT` and `PGDR_SECRET_FILE`
together. If the checkout moves, update both absolute paths in the config.
Reinstall deliberately preserves prior values rather than silently retargeting
an enabled schedule. Environment-file changes apply to the next job invocation.

## Run Once Through Systemd

Before enabling a schedule, run both installed services and inspect their output:

```bash
systemctl --user start postgres-dr-backup.service
systemctl --user start postgres-dr-backup-health.service
make schedule-status
journalctl --user -u postgres-dr-backup.service -n 80 --no-pager
journalctl --user -u postgres-dr-backup-health.service -n 80 --no-pager
```

Both services use `Type=oneshot`. A completed successful job normally returns to
`inactive`; it does not remain continuously running. Inspect `Result=success`
and `ExecMainStatus=0`, then confirm a recent successful invocation in the journal
and the completed backup with `make backup-info`. Default success values on a
never-run unit do not establish that a backup exists. The health job prints JSON
with the actual backup label and check results.

## Enable And Inspect The Schedule

```bash
make schedule-start
make schedule-status
```

| Timer | Schedule | Job |
| --- | --- | --- |
| `postgres-dr-backup.timer` | Daily at `02:00 UTC`, with up to five minutes randomized delay | Full backup and integrity verification |
| `postgres-dr-backup-health.timer` | Every hour at minutes `15` and `45`, UTC | Backup age and active WAL delivery check |

Both timers have `AccuracySec=1min`, so the configured time is a scheduling
window rather than an exact deadline. `schedule-status` prints the next/previous
timer activations and the last service results. Systemctl may display timestamps
in the host's local timezone even though the calendar expressions specify UTC.

`Persistent=true` requests one catch-up activation if a calendar event was missed
while the timer was inactive. It does not replay every missed daily backup or
retry a failed job continuously. The next timer event invokes the service again.

The scheduled health threshold is 26 hours, providing margin around the daily
backup time, jitter, and normal job duration. The standalone health command keeps
its existing 24-hour default. Neither interval is an established recovery objective.
Each active health check forces a WAL switch and may generate an archived segment
even when the database has no application writes.

## User Sessions And Reboots

A user manager depends on user-session lifetime. Check whether lingering is enabled
if jobs must run after logout or before login:

```bash
loginctl show-user "$USER" --property=Linger
```

An administrator can enable it explicitly:

```bash
sudo loginctl enable-linger "$USER"
```

Installation does not change lingering. Lingering also does not start the Docker
database after a host reboot. Ensure the intended primary is running; otherwise
the scheduled services fail and report that condition. A powered-off host cannot
run jobs; persistence only supplies a catch-up opportunity after the manager returns.

## Locking, Failures, And Logs

`make scheduled-backup` and `make scheduled-health` use
`.local/locks/schedule-PROJECT.lock` in the checkout. The shared exclusive lock
serializes the two operations for the same project. A second job waits up to
300 seconds by default and fails visibly if the lock remains held. Direct script
invocation uses exit `75` for lock contention; Make reports recipe failures as
exit `2`. Failed probes are not replaced with a cached healthy report.

The lock covers the scheduled entrypoints in one checkout. It does not coordinate
independent checkouts or every manually launched pgBackRest command. The underlying
backup and health commands retain their own error handling.

Systemd records nonzero service results and sends stdout/stderr to the user journal.
No email, webhook, or external alert transport is configured. A failed backup
must be investigated; inspect the health result and repository rather than
inferring backup success from an active timer.

To exercise failure reporting, stop the configured database and request a health
job. For the default local project:

```bash
make down
systemctl --user start postgres-dr-backup-health.service
# Expected: service start fails.
make schedule-status
journalctl --user -u postgres-dr-backup-health.service -n 80 --no-pager
```

Recover after fixing the cause:

```bash
make up
systemctl --user reset-failed postgres-dr-backup-health.service
systemctl --user start postgres-dr-backup-health.service
```

Backup jobs have a one-hour service timeout; health jobs have ten minutes. A service
timeout or manual termination affects the host launcher and does not establish
that an already-started command inside Docker has stopped. Inspect pgBackRest and
container activity before retrying such a job. Adjust timeouts with a systemd
drop-in when changing the lock wait or operating on larger datasets.

## Change Times, Stop, And Remove

An edit made with `systemctl --user edit` persists in the user's configuration
directory. Adding `--runtime` creates a temporary drop-in under
`$XDG_RUNTIME_DIR/systemd/user/`; it does not survive a reboot. `XDG_RUNTIME_DIR`
is the current user's runtime directory, commonly `/run/user/UID`. Inspect it with:

```bash
printf 'Runtime directory: %s\n' "${XDG_RUNTIME_DIR:-not set}"
```

In cleanup commands, `${XDG_RUNTIME_DIR:?}` makes Bash stop with an error if the
variable is unset or empty. Unlike `${VAR:-default}`, it provides no fallback;
this guards against constructing an unintended path when removing a drop-in.
Remove only the specific temporary file you created, then run
`systemctl --user daemon-reload` and restart the timer to apply its remaining settings.

Override the calendar with a drop-in, clearing the original expression first:

```bash
systemctl --user edit postgres-dr-backup.timer
```

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00:00 UTC
```

```bash
systemctl --user daemon-reload
systemctl --user restart postgres-dr-backup.timer
make schedule-status
```

Disable both timers without interrupting an active backup or check:

```bash
make schedule-stop
```

To disable timers and stop all running project containers from this checkout:

```bash
make stop-all
```

It preserves containers and data, and refuses container shutdown while a scheduled
job or pgBackRest backup is active. Wait for completion and repeat the command.
See [local commands](../README.md#local-commands) for scope and restart commands.

Remove the installed unit files when current jobs have finished:

```bash
make schedule-remove
```

Removal refuses while either service is active or transitioning. It retains
`schedule.env`, journal history, the checkout, password files, Docker resources,
and backups. Custom drop-ins are also retained; inspect them before reinstalling.

## Validation

```bash
make check
make schedule-acceptance
```

Static checks use the real systemd parser for all four units and both calendars.
Installer tests operate only in temporary config directories with a stubbed
`systemctl`, verify private config creation and preservation, and reject removal
while a job is running.

The existing disposable backup-health scenario additionally runs the same scheduled
Make entrypoints used by the units, creates a verified backup, parses healthy JSON,
checks lock contention, and rejects both jobs with a stopped primary. It installs
no user units and enables no timers. This proves unit definitions and job behavior.
A separate operator exercise on Ubuntu recorded service execution through the
user manager, a health run using a temporary 30-second timer, journal output,
stopped-primary failure, and return to healthy after restart. The normal calendar
intervals, logout/reboot behavior, and persistent catch-up were not exercised.
See [scheduling evidence](../evidence/backup-scheduling-acceptance-20261020.md).

## References

- [systemd timer documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
- [systemd service documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
- [Backup health](backup-health.md)
