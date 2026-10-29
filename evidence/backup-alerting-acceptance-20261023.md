# Backup Alerting Acceptance Evidence

- Result: PASS for local checks and live Telegram/Gmail delivery validation
- Date: `2026-10-23`
- CI and review: [PR #16](https://github.com/VlrRbn/postgres-disaster-recovery/pull/16)
- Source: working changes on `feat/backup-alerting`, based on `b363b5b`
- Runtime: Python `3.12`, Linux; standard-library delivery adapters
- External messages sent by automated tests: none
- Host user units or timers changed by automated tests: none

## Alert State And Job Integration

`make check` passed 60 test methods, including 22 alerting tests. The focused suite
is also available through `make alerts-acceptance`; all tests run in the existing
Foundation CI static-check entrypoint.

| Check | Observed Result |
| --- | --- |
| Initial success | No notification sent |
| Failure and recovery | One failure and one recovery per enabled channel; accepted repeats suppressed |
| Partial delivery | Only the failed channel retried; accepted delivery to the other channel retained |
| Recovery retry | Failed recovery retried without repeating the other channel's accepted message |
| Unnotified incident | No recovery sent to a channel that never accepted its failure message |
| Job/project separation | A healthy probe did not resolve a different backup job or project's failure |
| Recipient configuration | Changed channel settings did not inherit an earlier delivery acknowledgement |
| Invalid configuration | Malformed Telegram settings and email addresses did not block the valid channel |
| Config and state | Private creation, config preservation, exposed-file rejection, and no raw credentials in state verified |
| State failure | Corrupt state and an occupied lock refused delivery without resetting suppression history |
| Exit behavior | Original job failures retained; notification failure after a successful job produced a nonzero result |
| Shell entrypoint | Real scheduled shell wrapper and `flock` preserved JSON stdout and failed child status |

## Local TLS Transports

Tests generate short-lived certificates and bind HTTPS/SMTP servers only on
loopback interfaces and ephemeral ports. The Telegram connection is redirected
to the local fixture inside the test; production uses the fixed Telegram API
host. Production send functions perform real protocol exchanges in these checks.

| Check | Observed Result |
| --- | --- |
| Telegram request | HTTPS POST used the expected sendMessage path, chat ID, and text |
| Telegram acknowledgement | HTTP errors, `ok=false`, and missing message acknowledgement rejected |
| SMTP STARTTLS | TLS upgrade and message acceptance verified |
| SMTP implicit TLS | Message accepted through the SSL transport |
| SMTP authentication | Credentials exchanged over TLS in both modes |
| Trust validation | Untrusted server certificates rejected for both channels |
| Combined incident | Telegram accepted failure while SMTP returned `451`; the next run retried SMTP alone, then both received one recovery |

Provider exception text containing a dummy token was not copied into diagnostic
output. HTTP fixture access logging is disabled so dummy token paths are not logged.

## Scheduling Regression

`make schedule-acceptance` passed all nine stages through the updated wrapper:
missing/stale backup detection, archive outage and recovery, stopped-primary JSON,
verified full backup, health success, lock contention, and stopped-primary job
failures. Alert config/state paths were isolated in its temporary directory, so
configured recipients could not be used.

The project was `postgres-dr-health-test-1792779994-26207`. The retained local
report is `.local/reports/postgres-dr-health-test-1792779994-26207-health.json`.
Its containers, database/repository volumes, network, password, and schedule lock
were removed. Host timers were not installed or enabled.

ShellCheck, all Compose models, systemd unit/calendar validation, and diff
formatting passed as part of `make check`.

## Live Telegram And Gmail Validation

Sources: command output and received notifications on `2026-10-23`, using
`postgres-dr-local`. Recipient addresses, chat IDs, tokens, and SMTP credentials
are intentionally omitted.

| Check | Observed Result |
| --- | --- |
| Stopped-primary failure | Received `FAILED: backup-health` with UTC `2026-10-23T19:21:54.823894+00:00` and job exit status `2` |
| Telegram receipt | Failure message received; output recorded `telegram firing accepted by provider` |
| Gmail receipt | Failure email received; output recorded `email firing accepted by provider` |
| Repeated failed check | Repeating the failed check produced no second failure notification |
| Healthy retry after startup | Output recorded `telegram resolved accepted by provider` and `email resolved accepted by provider` |
| Recovery message | Recorded `RECOVERED: backup-health`, UTC `2026-10-23T19:24:03.591684+00:00`, job exit status `0` |

Recovery was accepted by both providers; receipt of each recovery message was
not independently verified. Repeated-success suppression and partial
provider outage handling were verified with local fixtures, not separately with
live providers. This exercise called scheduled entrypoints manually with timers
disabled; it does not establish unattended delivery across host reboots.

## Interpretation

Automated checks verify transport handling, state transitions, channel
independence, and scheduled-command integration. Live delivery checks confirmed
Telegram/Gmail failure receipt, repeated-failure suppression, and recovery
acceptance. These checks do not establish delivery while the host or scheduler
is unavailable, or behavior of other SMTP providers.

Retries require a later invocation of the same job. There is no durable delivery
queue or exactly-once guarantee. State remains local to the checkout and must be
retained for repeat suppression.
