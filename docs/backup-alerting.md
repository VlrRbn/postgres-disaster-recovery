# Backup Alerting

Optional Telegram and email notifications report failures and recovery of the
existing local scheduled backup and health jobs. Either channel can be enabled
alone, or both can receive the same job event. Configuration and delivery state
stay outside Git. No external messages are sent until a channel is configured,
enabled, and a scheduled job runs.

## Prepare Private Configuration

Run from the repository root:

```bash
make alerts-setup
```

This creates `.local/alerts/config.json` with mode `0600` and both channels
disabled. Repeating the command preserves existing configuration. Edit the file
locally; it contains credentials, so do not paste its completed contents into
issues, PRs, or terminal logs. The creating user must own the file, and group or
other-user permissions are refused.

```json
{
  "timeout_seconds": 10,
  "telegram": {
    "enabled": false,
    "bot_token": "",
    "chat_id": ""
  },
  "email": {
    "enabled": false,
    "host": "",
    "port": 587,
    "security": "starttls",
    "username": "",
    "password": "",
    "from": "",
    "to": ""
  }
}
```

The default path is relative to this checkout, not the current terminal
directory. If necessary, set `PGDR_ALERT_CONFIG` to another private file and
`PGDR_ALERT_STATE_DIR` to another state directory. For systemd jobs, add those
absolute paths to the existing private `schedule.env`; exporting variables in a
terminal does not configure installed services. No unit reinstall is needed for
changes to the alert JSON file.

## Configure Telegram

Create a bot with [BotFather](https://core.telegram.org/bots/tutorial#obtain-your-bot-token),
put its token in `telegram.bot_token`, and open a private conversation with the
bot and send `/start`. Keep `enabled` false while setting it up.

For a new bot without an active webhook, inspect chat IDs using `getUpdates`.
This reads the token from the private file, keeps it out of command arguments,
and prints only chat IDs:

```bash
python3 - <<'PY'
from contextlib import closing
from http.client import HTTPSConnection
import json
import sys
from scripts.backup_alerts import config_path, read_private_json

settings = read_private_json(config_path())['telegram']
with closing(HTTPSConnection('api.telegram.org', timeout=10)) as client:
    client.request('POST', f"/bot{settings['bot_token']}/getUpdates", '{}',
                   {'Content-Type': 'application/json'})
    response = client.getresponse()
    result = json.loads(response.read())
    if response.status != 200 or result.get('ok') is not True:
        sys.exit('Cannot read Telegram updates; inspect bot setup.')
    for update in result['result']:
        chat = update.get('message', {}).get('chat', {})
        if 'id' in chat:
            print(chat['id'])
PY
```

Set the intended ID as a JSON string, for example `"chat_id": "123456789"`,
then set `telegram.enabled` to `true`. An empty update list means no relevant
message was returned; send `/start` to the bot and retry. The delivery adapter
uses the fixed HTTPS endpoint `api.telegram.org` and checks both the HTTP status
and Telegram's message acknowledgement. It does not format messages as HTML or
Markdown. See [sendMessage](https://core.telegram.org/bots/api#sendmessage).

## Configure Email

Use SMTP settings from the provider or relay you operate. A complete example
with placeholder values is:

```json
"email": {
  "enabled": true,
  "host": "smtp.example.com",
  "port": 587,
  "security": "starttls",
  "username": "backup@example.com",
  "password": "PROVIDER_SMTP_CREDENTIAL",
  "from": "backup@example.com",
  "to": "ops@example.com"
}
```

Use `security=ssl` for implicit TLS, commonly on port `465`, or `starttls` for
an explicit TLS upgrade, commonly on port `587`. Both verify the server
certificate and hostname. Plain SMTP and TLS downgrade are unsupported.
Authentication occurs after TLS. Supply username and password together; an
unauthenticated TLS relay can leave both empty. Some providers require an app
password or SMTP to be enabled; OAuth-only SMTP authentication is outside this
implementation. Use one plain email address in each of `from` and `to`; a team
mailing-list address can be the recipient.

An accepted SMTP message can still be delayed, filtered, or bounced later.
The delivery result records server acceptance, not an inbox receipt. See
[Python SMTP client](https://docs.python.org/3/library/smtplib.html).

## Failure And Recovery Behavior

The existing `make scheduled-backup` and `make scheduled-health` commands invoke
the notifier after their job finishes, including a lock-contention failure.
Installed systemd services already use these entrypoints. Direct `make backup`
and `make backup-health` remain on-demand operations without notifications.

| Job result | Notification behavior |
| --- | --- |
| First successful run | No message |
| First failure | One `FAILED` message per enabled channel |
| Continued failure | Already accepted messages suppressed; failed delivery retried |
| Success after a notified failure | One `RECOVERED` message per channel that received `FAILED` |
| Continued success | No additional message; failed recovery delivery retried |

State is separate for each Compose project, job, and channel configuration.
A successful health check does not resolve a failed backup job: rerun that backup
job successfully to close its incident. Changing an enabled channel's settings
can cause a current failure to be sent again to that channel. No recovery message
is sent to a channel whose original failure notification was never accepted.

Private state and lock files are stored in `.local/alerts/state/`. Delivery is
recorded atomically after each successful channel send. A failed or invalid
channel does not block attempts to the other channel. Do not remove state to
retry normal delivery; a later run retries an undelivered event. Corrupt state or
an unavailable state lock causes a visible notification failure instead of
silently resetting suppression history.

Job stdout, including health JSON, is preserved. Notification diagnostics go to
stderr and the service journal without provider exception text, credentials, or
raw job output. A failed job retains its exit code. If the job succeeded but
notification handling failed, the wrapper returns nonzero and explicitly logs
that distinction; a `healthy` JSON report may therefore accompany a failed service.
Make converts recipe failures to its own nonzero exit code.

Retries happen on the next invocation of the same job; there is no background
queue. `timeout_seconds` is `1..30` seconds per network operation, not an overall
job deadline. The two channels are attempted sequentially. A crash between remote
acceptance and saving local state can cause a repeated message. Powered-off hosts,+a stopped user manager, and killed jobs cannot execute this notifier; external
monitoring is needed to detect those failures independently.

## Verify And Stop

Local tests send only to temporary loopback HTTPS and SMTP TLS servers:

```bash
make alerts-acceptance
make check
```

After configuring real recipients, an operator can exercise delivery with timers
disabled. These commands deliberately send notifications to the enabled channels:

```bash
make schedule-stop
make down
make scheduled-health
# Expected: unhealthy JSON, FAILED notifications, and a nonzero command result.
make scheduled-health
# Expected: continued failure, without repeating accepted FAILED messages.
make up
make scheduled-health
# Expected: healthy JSON and RECOVERED notifications.
make scheduled-health
# Expected: no additional recovery messages.
```

For service execution, use the same health service and journal commands described
in [backup scheduling](backup-scheduling.md). Disable either JSON channel with
`"enabled": false`; disabling both stops external delivery without deleting state.
`make schedule-stop` disables future timer activations; `make stop-all` also stops
the checkout's running project containers while retaining data. Neither command
deletes alert configuration or history. The local config is a file secret, not
an encrypted secret manager.

See [alerting evidence](../evidence/backup-alerting-acceptance-20261023.md) for
the verified boundary, including a separate Telegram/Gmail operator exercise.
Repeat live checks with your own recipients when configuring another environment.
