"""Validate private S3 configuration, temporary credentials, and policy boundaries."""

import configparser
import json
import io
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from scripts.setup_s3 import build_config, main, validate_settings, write_private, writer_policy


class S3SetupTests(unittest.TestCase):
    def setUp(self):
        self.settings = {'bucket': 'postgres-dr-example', 'region': 'eu-west-1',
                         'prefix': 'postgres-dr/orders', 'profile': 'test-profile', 'role_arn': None}
        self.credentials = {'AccessKeyId': 'TESTKEY', 'SecretAccessKey': 'synthetic-test-secret',
                            'SessionToken': 'synthetic-test-token',
                            'Expiration': '2026-10-06T13:00:00+00:00'}
        self.now = datetime(2026, 10, 6, 12, tzinfo=timezone.utc)

    def test_s3_has_verified_tls_prefix_and_shared_stanza_settings(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read_string(build_config(self.settings, self.credentials, now=self.now))
        self.assertEqual(config['global']['repo1-type'], 's3')
        self.assertEqual(config['global']['repo1-path'], '/postgres-dr/orders')
        self.assertEqual(config['global']['repo1-s3-endpoint'], 's3.eu-west-1.amazonaws.com')
        self.assertEqual(config['global']['repo1-storage-verify-tls'], 'y')
        self.assertEqual(config['global']['repo1-s3-token'], 'synthetic-test-token')
        self.assertEqual(config['global']['repo1-retention-full'], '2')
        self.assertEqual(config['global']['repo1-bundle'], 'y')
        self.assertEqual(config['orders']['pg1-path'], '/var/lib/postgresql/data')

    def test_expired_or_ambiguous_credentials_are_rejected(self):
        for changed in ({'Expiration': '2026-10-06T11:00:00+00:00'},
                        {'Expiration': '2026-10-06T13:00:00'}, {'SecretAccessKey': ''},
                        {'SessionToken': 'token\nrepo1-type=posix'}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                build_config(self.settings, {**self.credentials, **changed}, now=self.now)

    def test_settings_reject_path_escape_and_config_injection(self):
        for changed in ({'prefix': 'postgres-dr/../other'}, {'prefix': 'postgres-dr/orders/'},
                        {'prefix': 'postgres-dr//orders'}, {'bucket': 'bad\n[global]'},
                        {'region': 'eu-west-1\nrepo1-storage-verify-tls=n'},
                        {'role_arn': 'arn:aws:sts::123456789012:assumed-role/writer/session'}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                validate_settings({**self.settings, **changed})

    def test_writer_policy_only_covers_selected_bucket_prefix(self):
        policy = writer_policy(self.settings)['Statement']
        self.assertEqual(policy[0]['Action'], ['s3:ListBucket'])
        self.assertEqual(policy[0]['Condition']['StringLike']['s3:prefix'],
                         ['postgres-dr/orders', 'postgres-dr/orders/*'])
        self.assertEqual(policy[1]['Resource'], 'arn:aws:s3:::postgres-dr-example/postgres-dr/orders/*')
        self.assertNotIn('s3:DeleteObjectVersion', policy[1]['Action'])
        self.assertNotIn('s3:*', policy[1]['Action'])

    def test_private_write_replaces_credentials_with_mode_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'pgbackrest.conf'
            write_private(target, 'old synthetic credentials')
            target.chmod(0o644)
            write_private(target, 'new synthetic credentials')
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.read_text(), 'new synthetic credentials')
            self.assertEqual(list(target.parent.glob('.pgdr-*')), [])

    def test_repository_change_is_refused_before_credentials_or_files_are_touched(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'settings.json').write_text(json.dumps(self.settings))
            with patch.dict(os.environ, {'PGDR_S3_DIR': directory}, clear=True), \
                    patch('sys.argv', ['setup_s3.py', '--bucket', 'different-bucket']), \
                    patch('scripts.setup_s3.subprocess.run') as command, \
                    patch('sys.stderr', io.StringIO()), \
                    self.assertRaises(SystemExit):
                main()
            command.assert_not_called()
            self.assertFalse(Path(directory, 'pgbackrest.conf').exists())


if __name__ == '__main__':
    unittest.main()
