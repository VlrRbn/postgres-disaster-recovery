#!/usr/bin/env python3
"""Deliver optional Telegram and SMTP alerts for scheduled job state changes."""

import argparse
from datetime import datetime, timezone
from email.headerregistry import Address
from email.errors import HeaderParseError
from email.message import EmailMessage
from email.utils import format_datetime
import fcntl
import hashlib
from http.client import HTTPException, HTTPSConnection
import json
import os
from pathlib import Path
import re
import smtplib
import socket
import ssl
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = {
    'timeout_seconds': 10,
    'telegram': {'enabled': False, 'bot_token': '', 'chat_id': ''},
    'email': {'enabled': False, 'host': '', 'port': 587, 'security': 'starttls',
              'username': '', 'password': '', 'from': '', 'to': ''},
}


def config_path():
    return Path(os.environ.get('PGDR_ALERT_CONFIG', ROOT / '.local/alerts/config.json'))


def read_private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077 or metadata.st_size > 65536):
            raise ValueError('Expected an owned private JSON file of at most 64 KiB')
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError('Expected a JSON object')
    return value


def setup_config(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        read_private_json(path)
        print(f'Existing private alert configuration preserved: {path}')
    else:
        with os.fdopen(fd, 'w') as stream:
            json.dump(TEMPLATE, stream, indent=2)
            stream.write('\n')
        print(f'Private alert configuration created: {path}; both channels disabled.')


def validate_channel(name, settings):
    if not isinstance(settings, dict) or type(settings.get('enabled', False)) is not bool:
        raise ValueError('Expected channel settings with a boolean enabled flag')
    if not settings.get('enabled', False):
        return None
    if set(settings) - set(TEMPLATE[name]):
        raise ValueError('Unknown channel setting')
    required = ('bot_token', 'chat_id') if name == 'telegram' else ('host', 'from', 'to')
    if any(not isinstance(settings.get(key), str) or not settings[key] for key in required):
        raise ValueError('Required channel setting is empty')
    if name == 'telegram':
        if (not re.fullmatch(r'[0-9]+:[A-Za-z0-9_-]+', settings.get('bot_token', ''))
                or not re.fullmatch(r'-?[0-9]+|@[A-Za-z0-9_]+', settings.get('chat_id', ''))):
            raise ValueError('Invalid bot token or chat ID format')
    else:
        if (not settings.get('host') or any(c.isspace() for c in settings['host'])
                or type(settings.get('port')) is not int
                or not 1 <= settings['port'] <= 65535
                or settings.get('security') not in ('starttls', 'ssl')):
            raise ValueError('SMTP requires a host, valid port, and starttls or ssl')
        for field in ('from', 'to'):
            try:
                address = Address(addr_spec=settings[field])
            except (ValueError, HeaderParseError, IndexError) as error:
                raise ValueError('Expected one email address in each address field') from error
            if not address.username or not address.domain:
                raise ValueError('Expected one email address in each address field')
        username, password = settings.get('username', ''), settings.get('password', '')
        if not isinstance(username, str) or not isinstance(password, str) or bool(username) != bool(password):
            raise ValueError('SMTP username and password must be supplied together')
    return settings


def send_telegram(settings, message, timeout):
    payload = json.dumps({'chat_id': settings['chat_id'], 'text': message}).encode()
    connection = HTTPSConnection('api.telegram.org', timeout=timeout,
                                 context=ssl.create_default_context())
    try:
        connection.request('POST', f"/bot{settings['bot_token']}/sendMessage", payload,
                           {'Content-Type': 'application/json'})
        response = connection.getresponse()
        body = response.read(65537)
        if response.status != 200 or len(body) > 65536:
            raise ValueError('Telegram HTTP delivery failed')
        result = json.loads(body)
        if (not isinstance(result, dict) or result.get('ok') is not True
                or not isinstance(result.get('result'), dict)
                or type(result['result'].get('message_id')) is not int):
            raise ValueError('Telegram did not acknowledge a sent message')
    finally:
        connection.close()


def send_email(settings, message, timeout):
    mail = EmailMessage()
    mail['From'], mail['To'] = settings['from'], settings['to']
    mail['Subject'] = message.splitlines()[0]
    mail['Date'] = format_datetime(datetime.now(timezone.utc))
    mail.set_content(message)
    context = ssl.create_default_context()
    if settings['security'] == 'ssl':
        client = smtplib.SMTP_SSL(settings['host'], settings['port'], timeout=timeout, context=context)
    else:
        client = smtplib.SMTP(settings['host'], settings['port'], timeout=timeout)
    with client:
        client.ehlo()
        if settings['security'] == 'starttls':
            client.starttls(context=context)
            client.ehlo()
        if settings.get('username'):
            client.login(settings['username'], settings['password'])
        if client.send_message(mail):
            raise ValueError('SMTP recipient was refused')


def save_state(path, state):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.state-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def load_state(path):
    try:
        state = read_private_json(path)
    except FileNotFoundError:
        return {'schema_version': 1, 'incident': 0, 'unhealthy': False, 'channels': {}}
    if (state.get('schema_version') != 1 or type(state.get('incident')) is not int
            or state['incident'] < 0 or type(state.get('unhealthy')) is not bool
            or not isinstance(state.get('channels'), dict)):
        raise ValueError('Invalid alert state; inspect it before retrying')
    for entry in state['channels'].values():
        if (not isinstance(entry, dict) or type(entry.get('incident')) is not int
                or entry.get('phase') not in ('firing', 'resolved')
                or not isinstance(entry.get('recipient'), str)):
            raise ValueError('Invalid channel state')
    return state


def deliver_alerts(path, state_dir, project, job, result):
    try:
        config = read_private_json(path)
    except FileNotFoundError:
        return 0  # No configuration is the default opt-out.
    if set(config) - {'timeout_seconds', 'telegram', 'email'}:
        raise ValueError('Unknown alert configuration setting')
    timeout = config.get('timeout_seconds', 10)
    if type(timeout) is not int or not 1 <= timeout <= 30:
        raise ValueError('Alert timeout must be 1..30 seconds')
    channels, errors = {}, 0
    for name in ('telegram', 'email'):
        try:
            settings = validate_channel(name, config.get(name, {}))
            if settings is not None:
                channels[name] = settings
        except (ValueError, TypeError, KeyError):
            print(f'Alerts: invalid {name} configuration; inspect the private config.', file=sys.stderr)
            errors += 1
    if not channels:
        return errors

    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_path = state_dir / f'{project}-{job}.json'
    fd = os.open(state_path.with_suffix('.lock'), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = load_state(state_path)
        if result and not state['unhealthy']:
            state['incident'] += 1
        state['unhealthy'] = result != 0
        save_state(state_path, state)
        for name, settings in channels.items():
            recipient = hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()
            previous = state['channels'].get(name, {})
            same_recipient = previous.get('recipient') == recipient
            if result:
                if (same_recipient and previous.get('incident') == state['incident']
                        and previous.get('phase') == 'firing'):
                    continue
                phase = 'firing'
            elif same_recipient and previous.get('phase') == 'firing':
                phase = 'resolved'
            else:
                continue
            label = 'FAILED' if phase == 'firing' else 'RECOVERED'
            message = (f'[PostgreSQL DR] {label}: {job}\n'
                       f'Host: {socket.gethostname()}\nProject: {project}\n'
                       f'UTC: {datetime.now(timezone.utc).isoformat()}\n'
                       f'Job exit status: {result}\nInspect the service journal for details.')
            try:
                sender = send_telegram if name == 'telegram' else send_email
                sender(settings, message, timeout)
            except (OSError, ValueError, smtplib.SMTPException, HTTPException):
                # Provider exceptions may include credentials, token URLs, or recipients.
                print(f'Alerts: {name} {phase} delivery failed; retry on the next job run.', file=sys.stderr)
                errors += 1
                continue
            state['channels'][name] = {'recipient': recipient, 'phase': phase,
                                       'incident': state['incident']}
            save_state(state_path, state)
            print(f'Alerts: {name} {phase} accepted by provider.', file=sys.stderr)
    return errors


def run_job(job, command):
    try:
        result = subprocess.run(command, check=False).returncode
        if result < 0:
            result = 128 - result
    except OSError:
        print('Scheduled command could not start.', file=sys.stderr)
        result = 127
    project = os.environ.get('PGDR_PROJECT', 'postgres-dr-local')
    try:
        if not re.fullmatch(r'postgres-dr-[a-z0-9-]+', project):
            raise ValueError('Invalid project name')
        errors = deliver_alerts(config_path(), Path(os.environ.get(
            'PGDR_ALERT_STATE_DIR', ROOT / '.local/alerts/state')), project, job, result)
    except (OSError, ValueError, TypeError):
        print('Alerts: configuration or state unavailable; inspect private files and permissions.',
              file=sys.stderr)
        errors = 1
    if not result and errors:
        print(f'Alerts: {job} succeeded, but notification handling failed.', file=sys.stderr)
    return result if result else (1 if errors else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('setup', help='Create private configuration with both channels disabled')
    run = commands.add_parser('run', help='Run a scheduled command and report state changes')
    run.add_argument('job', choices=('backup', 'backup-health'))
    run.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'setup':
        try:
            setup_config(config_path())
        except (OSError, ValueError):
            parser.exit(2, 'Cannot prepare private alert configuration; inspect the file and permissions.\n')
        return 0
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('run requires a command after --')
    return run_job(args.job, command)


if __name__ == '__main__':
    raise SystemExit(main())
