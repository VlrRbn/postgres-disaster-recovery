"""Check freshness boundaries, historical archive errors, and unavailable inputs."""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import unittest

from scripts.backup_health import build_report, positive_seconds


class BackupHealthTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 3, 12, tzinfo=timezone.utc)
        self.stop = int(self.now.timestamp()) - 60
        self.info = [{'name': 'orders', 'status': {'code': 0, 'message': 'ok'},
                      'backup': [{'label': '20261003-115800F', 'type': 'full', 'error': False,
                                  'timestamp': {'stop': self.stop}}]}]
        self.archiver = {'in_recovery': False, 'archive_mode': 'on',
                         'archive_command_configured': True, 'failed_count': 0,
                         'last_archived_time': None}

    def report(self, **overrides):
        args = {'info': self.info, 'archiver': self.archiver, 'archive_error': None,
                'now': self.now, 'max_age': 60, 'archive_timeout': 10, 'project': 'postgres-dr-test'}
        args.update(overrides)
        return build_report(**args)

    def test_freshness_includes_limit_and_uses_completion_time(self):
        report = self.report()
        self.assertEqual(report['status'], 'healthy')
        self.assertEqual(report['checks']['backup_freshness']['age_seconds'], 60)
        report = self.report(max_age=59)
        self.assertEqual(report['status'], 'unhealthy')
        self.assertEqual(report['checks']['wal_delivery']['status'], 'ok')

    def test_latest_successful_full_backup_is_selected(self):
        newer = deepcopy(self.info[0]['backup'][0])
        newer['label'] = 'newer-full'
        newer['timestamp']['stop'] = self.stop + 20
        failed = deepcopy(newer)
        failed['error'] = True
        failed['timestamp']['stop'] = self.stop + 30
        self.info[0]['backup'] = [newer, failed, self.info[0]['backup'][0]]
        self.assertEqual(self.report()['checks']['backup_freshness']['label'], 'newer-full')

    def test_missing_backup_bad_metadata_and_future_time_fail(self):
        for info in (None, [], {}, [{'name': 'wrong'}],
                     [{'name': 'orders', 'status': {'code': 2, 'message': 'no valid backups'},
                       'backup': []}]):
            with self.subTest(info=info):
                self.assertEqual(self.report(info=info)['status'], 'unhealthy')
        self.info[0]['backup'][0]['timestamp']['stop'] = int(self.now.timestamp()) + 1
        report = self.report()
        self.assertEqual(report['checks']['backup_freshness']['status'], 'failed')

    def test_archive_failure_is_unhealthy_despite_recent_backup(self):
        report = self.report(archive_error='WAL did not reach the repository within 10 seconds')
        self.assertEqual(report['status'], 'unhealthy')
        self.assertEqual(report['checks']['backup_freshness']['status'], 'ok')

    def test_historical_failures_and_idle_timestamp_do_not_fail_active_success(self):
        self.archiver['failed_count'] = 9
        report = self.report()
        self.assertEqual(report['status'], 'healthy')
        self.assertEqual(report['archiver']['failed_count'], 9)

    def test_unavailable_or_disabled_primary_cannot_be_healthy(self):
        for archiver in (None, {}, {**self.archiver, 'archive_mode': 'off'},
                         {**self.archiver, 'in_recovery': True},
                         {**self.archiver, 'archive_command_configured': False}):
            with self.subTest(archiver=archiver):
                self.assertEqual(self.report(archiver=archiver)['status'], 'unhealthy')
        self.info[0]['status'] = {'code': 4, 'message': 'different database'}
        self.assertEqual(self.report()['status'], 'unhealthy')

    def test_invalid_thresholds_are_rejected(self):
        for value in ('0', '-1', '1.5', 'invalid'):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                positive_seconds(value)


if __name__ == '__main__':
    unittest.main()
