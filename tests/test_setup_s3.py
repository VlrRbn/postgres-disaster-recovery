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

    def test_instance_config_has_no_credentials_or_bootstrap_profile_requirement(self):
        settings = {**self.settings, 'auth_mode': 'instance', 'profile': None, 'role_arn': None}
        config = configparser.ConfigParser(interpolation=None)
        config.read_string(build_config(settings))
        self.assertEqual(config['global']['repo1-s3-key-type'], 'auto')
        self.assertEqual(config['global']['repo1-storage-verify-tls'], 'y')
        for option in ('repo1-s3-key', 'repo1-s3-key-secret', 'repo1-s3-token'):
            self.assertNotIn(option, config['global'])

    def test_authentication_modes_cannot_silently_mix_credentials(self):
        with self.assertRaises(ValueError):
            build_config({**self.settings, 'auth_mode': 'instance', 'profile': None}, self.credentials)
        with self.assertRaises(ValueError):
            build_config(self.settings)
        with self.assertRaises(ValueError):
            validate_settings({**self.settings, 'auth_mode': 'unknown'})
        for field, value in (('profile', 'test-profile'),
                             ('role_arn', 'arn:aws:iam::123456789012:role/writer')):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'attached EC2 role'):
                validate_settings({**self.settings, 'auth_mode': 'instance',
                                   'profile': None, 'role_arn': None, field: value})

    def test_instance_cli_rejects_explicit_profile_inputs_before_writing(self):
        for field, value in (('profile', 'test-profile'),
                             ('role_arn', 'arn:aws:iam::123456789012:role/writer')):
            for source in ('environment', 'argument'):
                with self.subTest(field=field, source=source), tempfile.TemporaryDirectory() as directory:
                    environment = {'PGDR_S3_DIR': directory, 'PGDR_S3_BUCKET': self.settings['bucket'],
                                   'PGDR_S3_REGION': self.settings['region'], 'PGDR_S3_AUTH_MODE': 'instance'}
                    arguments = ['setup_s3.py']
                    if source == 'environment':
                        environment[f'PGDR_S3_{field.upper()}'] = value
                    else:
                        arguments.extend([f'--{field.replace("_", "-")}', value])
                    with patch.dict(os.environ, environment, clear=True), \
                            patch('sys.argv', arguments), \
                            patch('scripts.setup_s3.fetch_credentials') as fetch, \
                            patch('sys.stderr', io.StringIO()) as errors, \
                            self.assertRaises(SystemExit) as failure:
                        main()
                    self.assertEqual(failure.exception.code, 2)
                    self.assertIn(f'unset PGDR_S3_{field.upper()}', errors.getvalue())
                    fetch.assert_not_called()
                    self.assertEqual(list(Path(directory).iterdir()), [])

    def test_instance_cli_runs_without_aws_cli_or_prior_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = {'PGDR_S3_DIR': directory, 'PGDR_S3_BUCKET': self.settings['bucket'],
                           'PGDR_S3_REGION': self.settings['region'], 'PGDR_S3_AUTH_MODE': 'instance'}
            with patch.dict(os.environ, environment, clear=True), \
                    patch('sys.argv', ['setup_s3.py']), \
                    patch('scripts.setup_s3.fetch_credentials') as fetch, \
                    patch('sys.stdout', io.StringIO()):
                main()
            fetch.assert_not_called()
            saved = json.loads(Path(directory, 'settings.json').read_text())
            self.assertEqual(saved['auth_mode'], 'instance')
            self.assertIsNone(saved['profile'])

    def test_profile_cli_preserves_saved_profile_and_role(self):
        settings = {**self.settings, 'role_arn': 'arn:aws:iam::123456789012:role/writer'}
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'settings.json').write_text(json.dumps(settings))
            with patch.dict(os.environ, {'PGDR_S3_DIR': directory}, clear=True), \
                    patch('sys.argv', ['setup_s3.py']), \
                    patch('scripts.setup_s3.fetch_credentials',
                          return_value={**self.credentials, 'Expiration': None}) as fetch, \
                    patch('sys.stdout', io.StringIO()):
                main()
            fetch.assert_called_once_with({**settings, 'auth_mode': 'profile'})
            saved = json.loads(Path(directory, 'settings.json').read_text())
            self.assertEqual(saved['profile'], settings['profile'])
            self.assertEqual(saved['role_arn'], settings['role_arn'])

    def test_switch_to_instance_mode_removes_previous_file_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            saved_settings = {**self.settings, 'role_arn': 'arn:aws:iam::123456789012:role/writer'}
            Path(directory, 'settings.json').write_text(json.dumps(saved_settings))
            config_path = Path(directory, 'pgbackrest.conf')
            config_path.write_text(build_config(self.settings, self.credentials, now=self.now))
            with patch.dict(os.environ, {'PGDR_S3_DIR': directory, 'PGDR_S3_AUTH_MODE': 'instance'}, clear=True), \
                    patch('sys.argv', ['setup_s3.py']), \
                    patch('scripts.setup_s3.fetch_credentials') as fetch, \
                    patch('sys.stdout', io.StringIO()):
                main()
            fetch.assert_not_called()
            content = config_path.read_text()
            self.assertNotIn(self.credentials['AccessKeyId'], content)
            self.assertNotIn(self.credentials['SecretAccessKey'], content)
            self.assertNotIn(self.credentials['SessionToken'], content)
            self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)
            saved = json.loads(Path(directory, 'settings.json').read_text())
            self.assertIsNone(saved['profile'])
            self.assertIsNone(saved['role_arn'])

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
