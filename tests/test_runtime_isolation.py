"""Check runtime selection and acceptance cleanup without accessing Docker or AWS."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOCAL_ACCEPTANCE = (
    ('acceptance.sh', (), 'postgres-dr-test-'),
    ('rpo-acceptance.sh', (), 'postgres-dr-rpo-test-'),
    ('backup-health-acceptance.sh', (), 'postgres-dr-health-test-'),
    ('backup-health-acceptance.sh', ('--schedule',), 'postgres-dr-health-test-'),
    ('pgadmin-acceptance.sh', (), 'postgres-dr-ui-test-'),
)


class RuntimeIsolationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='pgdr isolation ')
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name)
        # Even setup and failed cleanup operate only inside this temporary checkout.
        self.checkout = self.path / 'checkout'
        scripts = self.checkout / 'scripts'
        scripts.mkdir(parents=True)
        for name in {'compose.sh', 'setup.sh', 'backup.sh', 'backup_health.py', 'backup_alerts.py',
                     *(case[0] for case in LOCAL_ACCEPTANCE)}:
            shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
        shutil.copyfile(ROOT / 'Makefile', self.checkout / 'Makefile')
        fake_bin = self.path / 'bin'
        fake_bin.mkdir()
        self.calls = self.path / 'docker.jsonl'
        self.state = self.path / 'docker-state.json'
        self.aws_calls = self.path / 'aws-called'
        self.temporary = self.path / 'temporary'
        self.temporary.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('PGDR_', 'COMPOSE_', 'BASH_FUNC_'))
                    and key not in ('BASH_ENV', 'ENV', 'MAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES')}
        self.env.update(PATH=f'{fake_bin}:{os.environ["PATH"]}', TMPDIR=str(self.temporary),
                        PGDR_TEST_DOCKER_CALLS=str(self.calls),
                        PGDR_TEST_DOCKER_STATE=str(self.state),
                        PGDR_TEST_AWS_CALLS=str(self.aws_calls), PYTHONDONTWRITEBYTECODE='1')
        docker = fake_bin / 'docker'
        docker.write_text(f'#!{sys.executable}\n' +
                          (ROOT / 'tests/fixtures/runtime_isolation_docker.py').read_text())
        docker.chmod(0o755)
        # Any accidental cloud setup must fail locally, before an AWS CLI can run.
        aws = fake_bin / 'aws'
        aws.write_text('#!/bin/sh\ntouch "$PGDR_TEST_AWS_CALLS"\n'
                       'echo "AWS is forbidden in isolation tests" >&2\nexit 99\n')
        aws.chmod(0o755)
        # The scheduling target still runs through Make, without consulting host timers.
        for name in ('systemd-analyze', 'systemctl'):
            command = fake_bin / name
            command.write_text('#!/bin/sh\nexit ' + ('0' if name == 'systemd-analyze' else '99') + '\n')
            command.chmod(0o755)

    def recorded_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def compose(self, *arguments, **environment):
        self.calls.unlink(missing_ok=True)
        return subprocess.run(['bash', str(self.checkout / 'scripts/compose.sh'), *arguments],
                              env=dict(self.env, **environment), capture_output=True, text=True, timeout=5)

    def assert_selection(self, call, project, *files):
        args = call['args']
        self.assertEqual(args[:3], ['compose', '--project-name', project])
        selected = [args[index + 1] for index, value in enumerate(args) if value == '--file']
        self.assertEqual(selected, [str(self.checkout / name) for name in files])

    def test_local_backend_rejects_reserved_projects_before_docker(self):
        for repository in ({}, {'PGDR_REPOSITORY': 'local'}):
            for runtime in ('s3', 'patroni', 'replication'):
                for suffix in ('', '-custom', '-s3-custom', '-'):
                    project = f'postgres-dr-{runtime}{suffix}'
                    with self.subTest(repository=repository, project=project):
                        result = self.compose('down', '--volumes', PGDR_PROJECT=project, **repository)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('reserved', result.stderr)
                        self.assertEqual(self.recorded_calls(), [])

    def test_other_runtime_project_mismatches_are_rejected_before_docker(self):
        cases = (
            ((), {'PGDR_REPOSITORY': 's3', 'PGDR_PROJECT': 'postgres-dr-local'}),
            (('--replication',), {'PGDR_REPLICATION_PROJECT': 'postgres-dr-local'}),
            (('--patroni',), {'PGDR_PATRONI_PROJECT': 'postgres-dr-local'}),
            (('--patroni',), {'PGDR_PATRONI_REPOSITORY': 's3', 'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni'}),
            (('--patroni',), {'PGDR_PATRONI_REPOSITORY': 'local', 'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni-s3-custom'}),
        )
        for arguments, environment in cases:
            with self.subTest(arguments=arguments, environment=environment):
                result = self.compose(*arguments, 'down', '--volumes', **environment)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.recorded_calls(), [])

    def test_valid_local_names_keep_their_projects_and_configuration(self):
        for project in ('postgres-dr-local', 'postgres-dr-custom-2026', 'postgres-dr-test-123-456',
                        'postgres-dr-s3backup', 'postgres-dr-patronix', 'postgres-dr-replicationtest',
                        'postgres-dr--custom', 'postgres-dr-custom-'):
            with self.subTest(project=project):
                result = self.compose('config', '--quiet', PGDR_REPOSITORY='local', PGDR_PROJECT=project)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.recorded_calls()
                self.assertEqual(len(calls), 1)
                self.assert_selection(calls[0], project, 'compose.yaml')

    def test_invalid_local_project_syntax_is_still_rejected_before_docker(self):
        for project in ('unrelated-app', 'postgres-dr-UPPER', 'postgres-dr-under_score', 'postgres-dr-'):
            with self.subTest(project=project):
                self.assertNotEqual(self.compose('down', '--volumes', PGDR_PROJECT=project).returncode, 0)
                self.assertEqual(self.recorded_calls(), [])

    def test_valid_runtime_selections_and_defaults_reach_docker(self):
        cases = (
            ((), {}, 'postgres-dr-local', ('compose.yaml',)),
            ((), {'PGDR_REPOSITORY': 's3'}, 'postgres-dr-s3', ('compose.s3.yaml',)),
            ((), {'PGDR_REPOSITORY': 's3', 'PGDR_PROJECT': 'postgres-dr-s3-custom', 'PGDR_S3_FIXTURE': '1'},
             'postgres-dr-s3-custom', ('compose.s3.yaml', 'compose.s3-test.yaml')),
            (('--replication',), {}, 'postgres-dr-replication', ('compose.replication.yaml',)),
            (('--replication',), {'PGDR_REPOSITORY': 'patroni', 'PGDR_PROJECT': 'postgres-dr-s3-existing',
                                  'PGDR_REPLICATION_PROJECT': 'postgres-dr-replication-custom'},
             'postgres-dr-replication-custom', ('compose.replication.yaml',)),
            (('--patroni',), {}, 'postgres-dr-patroni', ('compose.patroni.yaml',)),
            ((), {'PGDR_REPOSITORY': 'patroni', 'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni-custom'},
             'postgres-dr-patroni-custom', ('compose.patroni.yaml',)),
            (('--patroni',), {'PGDR_PATRONI_REPOSITORY': 's3'},
             'postgres-dr-patroni-s3', ('compose.patroni.yaml', 'compose.patroni-s3.yaml')),
            (('--patroni',), {'PGDR_PATRONI_REPOSITORY': 's3', 'PGDR_S3_FIXTURE': '1',
                              'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni-s3-custom'},
             'postgres-dr-patroni-s3-custom',
             ('compose.patroni.yaml', 'compose.patroni-s3.yaml', 'compose.patroni-s3-test.yaml')),
        )
        for arguments, environment, project, files in cases:
            with self.subTest(arguments=arguments, environment=environment):
                result = self.compose(*arguments, 'config', '--quiet', **environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.recorded_calls()
                self.assertEqual(len(calls), 1)
                self.assert_selection(calls[0], project, *files)

    def test_local_acceptance_startup_and_cleanup_ignore_inherited_runtimes(self):
        existing_config = self.path / 'existing-config'
        existing_config.mkdir()
        marker = existing_config / 'config'
        marker.write_text('preserve existing configuration\n')
        inherited = {
            'PGDR_PROJECT': 'postgres-dr-s3-existing',
            'PGDR_SECRET_FILE': str(marker), 'PGDR_S3_DIR': str(existing_config),
            'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni-s3-existing',
            'PGDR_PATRONI_REPOSITORY': 's3', 'PGDR_PATRONI_DIR': str(existing_config),
            'PGDR_REPLICATION_PROJECT': 'postgres-dr-replication-existing',
            'PGDR_REPLICATION_DIR': str(existing_config),
            'PGDR_TEST_FAIL_UP': '1',
        }
        for script, arguments, prefix in LOCAL_ACCEPTANCE:
            for repository in ('local', 's3', 'patroni'):
                for fixture in ('0', '1'):
                    with self.subTest(script=script, arguments=arguments, repository=repository, fixture=fixture), \
                            tempfile.TemporaryDirectory(dir=self.temporary) as temporary:
                        self.calls.unlink(missing_ok=True)
                        env = dict(self.env, **inherited, PGDR_REPOSITORY=repository,
                                   PGDR_S3_FIXTURE=fixture, TMPDIR=temporary)
                        result = subprocess.run(['bash', str(self.checkout / 'scripts' / script), *arguments],
                                                env=env, capture_output=True, text=True, timeout=10)
                        self.assertNotEqual(result.returncode, 0)
                        calls = self.recorded_calls()
                        self.assertEqual(len(calls), 3, result.stdout + result.stderr)
                        project = calls[0]['args'][2]
                        self.assertTrue(project.startswith(prefix), project)
                        self.assertRegex(project[len(prefix):], r'^[0-9]+-[0-9]+$')
                        for call in calls:
                            self.assert_selection(call, project, 'compose.yaml')
                            self.assertEqual(call['repository'], 'local')
                            self.assertEqual(call['fixture'], '0')
                        self.assertIn('up', calls[0]['args'])
                        self.assertIn('logs', calls[1]['args'])
                        self.assertEqual(calls[2]['args'][-3:], ['down', '--volumes', '--remove-orphans'])
                        self.assertEqual(list(Path(temporary).iterdir()), [])
                        self.assertEqual(list(existing_config.iterdir()), [marker])
                        self.assertEqual(marker.read_text(), 'preserve existing configuration\n')

    def make_acceptance(self, target, repository, project, lifecycle, *, fail_up=False):
        self.calls.unlink(missing_ok=True)
        self.state.unlink(missing_ok=True)
        existing_config = self.path / 'existing-config'
        existing_config.mkdir(exist_ok=True)
        for name in ('postgres_password', 'pgadmin_password', 'alerts.json', 'state-marker'):
            path = existing_config / name
            path.write_text('preserve existing configuration\n')
            path.chmod(0o600)
        before = {path.name: path.read_bytes() for path in existing_config.iterdir()}
        settings = {
            'PGDR_PROJECT': project, 'PGDR_REPOSITORY': repository,
            'PGDR_S3_FIXTURE': '0' if repository == 'local' else '1',
            'PGDR_SECRET_FILE': str(existing_config / 'postgres_password'),
            'PGDR_PGADMIN_SECRET_FILE': str(existing_config / 'pgadmin_password'), 'PGADMIN_PORT': '15432',
            'PGDR_ALERT_CONFIG': str(existing_config / 'alerts.json'), 'PGDR_ALERT_STATE_DIR': str(existing_config),
            'PGDR_S3_DIR': str(existing_config), 'PGDR_PATRONI_DIR': str(existing_config),
            'PGDR_PATRONI_PROJECT': 'postgres-dr-patroni-s3-existing', 'PGDR_PATRONI_REPOSITORY': 's3',
        }
        # Use the public target and the production Makefile, with a real Make executable.
        result = subprocess.run(['make', '--no-print-directory', '--directory=' + str(self.checkout),
                                 target, *(f'{key}={value}' for key, value in settings.items())],
                                env=dict(self.env, PGDR_TEST_LIFECYCLE=lifecycle,
                                         PGDR_TEST_FAIL_UP='1' if fail_up else '0'),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(before, {path.name: path.read_bytes() for path in existing_config.iterdir()})
        self.assertFalse(self.aws_calls.exists(), 'Acceptance tried to invoke AWS')
        self.assertEqual(list(self.temporary.iterdir()), [], result.stdout + result.stderr)
        return result, self.recorded_calls()

    def assert_temporary_make_settings(self, calls, prefix):
        self.assertTrue(calls)
        self.assertIn('up', calls[0]['args'])
        project = calls[0]['args'][2]
        self.assertRegex(project, '^' + prefix + r'[0-9]+-[0-9]+$')
        work = Path(calls[0]['settings']['PGDR_SECRET_FILE']).parent
        self.assertEqual(work.parent, self.temporary)
        for call in calls:
            self.assert_selection(call, project, 'compose.yaml')
            settings = call['settings']
            self.assertEqual(settings['PGDR_PROJECT'], project)
            self.assertEqual(settings['PGDR_REPOSITORY'], 'local')
            self.assertEqual(settings['PGDR_S3_FIXTURE'], '0')
            self.assertEqual(settings['PGDR_SECRET_FILE'], str(work / 'postgres_password'))
            if prefix == 'postgres-dr-ui-test-':
                self.assertEqual(settings['PGDR_PGADMIN_SECRET_FILE'], str(work / 'pgadmin_password'))
                self.assertEqual(settings['PGADMIN_PORT'], '0')
            else:
                self.assertEqual(settings['PGDR_ALERT_CONFIG'], str(work / 'alerts.json'))
                self.assertEqual(settings['PGDR_ALERT_STATE_DIR'], str(work / 'alert-state'))
        self.assertEqual(calls[-1]['args'][-3:], ['down', '--volumes', '--remove-orphans'])

    def test_pgadmin_public_make_target_ignores_command_line_settings(self):
        for repository, project in (('local', 'postgres-dr-local'), ('s3', 'postgres-dr-s3-existing'),
                                    ('patroni', 'postgres-dr-patroni-s3-existing')):
            for fail_up in (True, False):
                with self.subTest(repository=repository, fail_up=fail_up):
                    result, calls = self.make_acceptance('pgadmin-acceptance', repository, project,
                                                         'pgadmin', fail_up=fail_up)
                    self.assertNotEqual(result.returncode, 0)  # Injected startup failure.
                    self.assert_temporary_make_settings(calls, 'postgres-dr-ui-test-')
                    self.assertIn('logs', calls[-2]['args'])
                    if not fail_up:
                        self.assertTrue(any(call['args'][-1] == 'pgadmin' and 'up' in call['args']
                                            for call in calls), result.stdout + result.stderr)
                        self.assertEqual(sum(call['args'][-1] == 'stanza-create' for call in calls), 2)

    def test_schedule_public_make_target_isolates_nested_jobs_and_cleanup(self):
        for repository, project in (('local', 'postgres-dr-local'), ('s3', 'postgres-dr-s3-existing'),
                                    ('patroni', 'postgres-dr-patroni-s3-existing')):
            for lifecycle in ('schedule', 'schedule-failure'):
                with self.subTest(repository=repository, lifecycle=lifecycle):
                    result, calls = self.make_acceptance('schedule-acceptance', repository, project, lifecycle)
                    self.assert_temporary_make_settings(calls, 'postgres-dr-health-test-')
                    backups = [index for index, call in enumerate(calls) if call['args'][-1] == 'backup']
                    self.assertEqual(len(backups), 2, result.stdout + result.stderr)
                    if lifecycle == 'schedule-failure':
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('Injected scheduled backup failure', result.stderr)
                        self.assertIn('logs', calls[-2]['args'])
                    else:
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn('lock contention and stopped-primary jobs fail', result.stdout)
                        # The second full backup and the following health SQL use nested scheduled Make jobs.
                        self.assertTrue(any('json_build_object' in call['args'][-1]
                                            for call in calls[backups[1] + 1:]))


if __name__ == '__main__':
    unittest.main()
