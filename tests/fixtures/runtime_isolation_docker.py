"""Docker command fixture for acceptance isolation tests; never contacts a daemon."""

import json
import os
from pathlib import Path
import sys
import time


def main():
    args = sys.argv[1:]
    settings: dict[str, str | None] = {
        key: value for key, value in os.environ.items() if key.startswith('PGDR_')
    }
    settings['PGADMIN_PORT'] = os.environ.get('PGADMIN_PORT')
    with open(os.environ['PGDR_TEST_DOCKER_CALLS'], 'a') as stream:
        stream.write(json.dumps({'args': args, 'repository': settings.get('PGDR_REPOSITORY'),
                                 'fixture': settings.get('PGDR_S3_FIXTURE'), 'settings': settings}) + '\n')
    if not args or args[0] != 'compose':
        sys.exit('Unexpected Docker command in isolation test')
    position = 1
    while position < len(args) and args[position] in (
            '--project-name', '--project-directory', '--file', '--profile'):
        position += 2
    operation = args[position] if position < len(args) else None
    if operation == 'up' and os.environ.get('PGDR_TEST_FAIL_UP') == '1':
        return 73
    lifecycle = os.environ.get('PGDR_TEST_LIFECYCLE')
    if not lifecycle:
        if operation not in ('config', 'up', 'logs', 'down'):
            sys.exit('Unexpected Compose operation in isolation test')
        return 0

    path = Path(os.environ['PGDR_TEST_DOCKER_STATE'])
    state = json.loads(path.read_text()) if path.exists() else {
        'running': False, 'initialized': False, 'backup': None, 'backups': 0,
        'archive_writable': True, 'failed_count': 0,
    }
    result = lifecycle_command(operation, args[position + 1:], state, lifecycle)
    path.write_text(json.dumps(state))
    return result


def lifecycle_command(operation, args, state, lifecycle):
    if operation == 'up':
        if args[-1] == 'pgadmin':
            return 73  # Stop before browser/network checks, after both nested Make targets.
        state['running'] = True
    elif operation == 'stop':
        state['running'] = False
    elif operation in ('logs', 'down', 'restart', 'ps'):
        pass
    elif operation == 'exec':
        if not state['running']:
            print('Fixture database is stopped.', file=sys.stderr)
            return 1
        if 'pgbackrest' in args:
            return pgbackrest(args[-1], state, lifecycle)
        if 'psql' in args:
            query = args[-1]
            if 'json_build_object' in query:
                print(json.dumps({'in_recovery': False, 'archive_mode': 'on',
                                  'archive_command_configured': True,
                                  'failed_count': state['failed_count']}))
            elif 'SELECT count(*)' in query:
                print(1)
            elif 'INSERT INTO orders' not in query:
                sys.exit('Unexpected SQL in isolation fixture')
        elif 'chmod' in args:
            state['archive_writable'] = 'u+w' in args
        else:
            sys.exit('Unexpected exec in isolation fixture')
    else:
        sys.exit('Unexpected Compose operation in lifecycle fixture')
    return 0


def pgbackrest(command, state, lifecycle):
    if command == 'stanza-create':
        state['initialized'] = True
    elif not state['initialized']:
        print('Fixture archive.info is missing.', file=sys.stderr)
        return 55
    elif command == 'check':
        if not state['archive_writable']:
            state['failed_count'] += 1
            print('Fixture archive is unavailable.', file=sys.stderr)
            return 1
    elif command == 'backup':
        state['backups'] += 1
        if lifecycle == 'schedule-failure' and state['backups'] == 2:
            print('Injected scheduled backup failure.', file=sys.stderr)
            return 73
        state['backup'] = {'label': '20261122-120000F', 'type': 'full', 'error': False,
                           'timestamp': {'stop': int(time.time())}}
    elif command == 'info':
        print(json.dumps([{'name': 'orders', 'status': {'code': 0, 'message': 'ok'},
                           'backup': [state['backup']] if state['backup'] else []}]))
    elif command == 'verify':
        print('status: ok')
    else:
        sys.exit('Unexpected pgBackRest command in isolation fixture')
    return 0


if __name__ == '__main__':
    sys.exit(main())
