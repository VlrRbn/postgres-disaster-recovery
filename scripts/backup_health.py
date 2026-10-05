#!/usr/bin/env python3
"""Check completed backup freshness and actively verify WAL archive delivery."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess


ARCHIVER_SQL = """
SELECT json_build_object(
    'archive_mode', current_setting('archive_mode'),
    'archive_command_configured', current_setting('archive_command') <> '',
    'in_recovery', pg_is_in_recovery(),
    'archived_count', archived_count,
    'last_archived_wal', last_archived_wal,
    'last_archived_time', last_archived_time,
    'failed_count', failed_count,
    'last_failed_wal', last_failed_wal,
    'last_failed_time', last_failed_time,
    'stats_reset', stats_reset
) FROM pg_stat_archiver;
"""


def positive_seconds(value):
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError('Use a positive integer number of seconds') from error
    if seconds <= 0:
        raise argparse.ArgumentTypeError('Use a positive integer number of seconds')
    return seconds


def build_report(info, archiver, archive_error, *, now, max_age, archive_timeout,
                 project, collection_errors=None):
    errors = collection_errors or {}
    checks = {}
    latest = None
    try:
        if info is None:
            raise ValueError(errors.get('repository', 'Repository metadata is unavailable'))
        if len(info) != 1 or info[0]['name'] != 'orders':
            raise ValueError('Expected exactly one orders stanza')
        stanza = info[0]
        checks['repository'] = {
            'status': 'ok' if stanza['status']['code'] == 0 else 'failed',
            'detail': stanza['status']['message'],
        }
        completed = [backup for backup in stanza['backup']
                     if backup['type'] == 'full' and backup['error'] is False
                     and type(backup['timestamp']['stop']) is int
                     and backup['timestamp']['stop'] > 0]
        if completed:
            latest = max(completed, key=lambda backup: backup['timestamp']['stop'])
    except (ValueError, KeyError, TypeError, IndexError) as error:
        checks['repository'] = {'status': 'failed', 'detail': f'Cannot read repository: {error}'}

    try:
        if latest is None:
            raise ValueError('No completed full backup is available; run make backup')
        completed_at = datetime.fromtimestamp(latest['timestamp']['stop'], timezone.utc)
        age = (now - completed_at).total_seconds()
        if age < 0:
            raise ValueError('Backup completion is in the future; check host and database clocks')
        checks['backup_freshness'] = {
            'status': 'ok' if age <= max_age else 'failed',
            'detail': 'Completed full backup is within the age limit' if age <= max_age
                      else 'Completed full backup is too old; run make backup',
            'label': latest['label'],
            'completed_utc': completed_at.isoformat(),
            'age_seconds': round(age, 3),
        }
    except (ValueError, KeyError, TypeError, OverflowError, OSError) as error:
        checks['backup_freshness'] = {'status': 'failed', 'detail': str(error)}

    checks['wal_delivery'] = {
        'status': 'ok' if archive_error is None else 'failed',
        'detail': archive_error or 'Active pgBackRest WAL delivery check passed',
    }
    try:
        if archiver is None:
            raise ValueError(errors.get('database', 'Archiver statistics are unavailable'))
        if (archiver['in_recovery'] is not False
                or archiver['archive_mode'] not in ('on', 'always')
                or archiver['archive_command_configured'] is not True):
            raise ValueError('Expected a primary database with WAL archiving enabled')
        checks['database'] = {'status': 'ok', 'detail': 'Primary is reachable with archiving enabled'}
    except (ValueError, KeyError, TypeError) as error:
        checks['database'] = {'status': 'failed', 'detail': str(error)}

    return {
        'schema_version': 1,
        'status': 'healthy' if all(check['status'] == 'ok' for check in checks.values())
                  else 'unhealthy',
        'project': project,
        'stanza': 'orders',
        'observed_utc': now.isoformat(),
        'limits': {'backup_max_age_seconds': max_age, 'archive_timeout_seconds': archive_timeout},
        'checks': checks,
        'archiver': archiver,
    }


def run_command(command, timeout):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f'Command exceeded its {timeout}-second host timeout') from error
    except OSError as error:
        raise RuntimeError(str(error)) from error
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(detail[-2000:] or f'Command exited with status {result.returncode}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup-max-age-seconds', type=positive_seconds,
                        default=os.environ.get('PGDR_BACKUP_MAX_AGE_SECONDS', '86400'))
    parser.add_argument('--archive-timeout-seconds', type=positive_seconds,
                        default=os.environ.get('PGDR_ARCHIVE_TIMEOUT_SECONDS', '10'))
    args = parser.parse_args()
    if args.archive_timeout_seconds > 86400:
        parser.error('Archive timeout must be at most 86400 seconds')

    root = Path(__file__).resolve().parent.parent
    compose = ['bash', str(root / 'scripts/compose.sh'), 'exec', '-T', '--user', 'postgres', 'postgres']
    pgbackrest = [*compose, 'pgbackrest', '--stanza=orders', '--log-level-console=error']
    errors = {}
    info = None
    try:
        info = json.loads(run_command([*pgbackrest, '--output=json', 'info'], timeout=30))
    except (RuntimeError, ValueError) as error:
        errors['repository'] = str(error)

    archive_error = None
    try:
        run_command([*pgbackrest, f'--archive-timeout={args.archive_timeout_seconds}', 'check'],
                    timeout=args.archive_timeout_seconds + 30)
    except RuntimeError as error:
        archive_error = str(error)

    archiver = None
    try:
        archiver = json.loads(run_command(
            [*compose, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'orders',
             '-Atc', ARCHIVER_SQL], timeout=30))
    except (RuntimeError, ValueError) as error:
        errors['database'] = str(error)

    report = build_report(info, archiver, archive_error, now=datetime.now(timezone.utc),
                          max_age=args.backup_max_age_seconds,
                          archive_timeout=args.archive_timeout_seconds,
                          project=os.environ.get('PGDR_PROJECT', 'postgres-dr-local'),
                          collection_errors=errors)
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'healthy' else 1


if __name__ == '__main__':
    raise SystemExit(main())
