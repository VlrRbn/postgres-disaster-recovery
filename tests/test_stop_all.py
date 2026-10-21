"""Exercise stop-all selection and refusal paths without stopping real containers."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StopAllTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name)
        fake_bin = self.path / 'bin'
        fake_bin.mkdir()
        self.calls = self.path / 'calls.jsonl'
        self.config = self.path / 'config'
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.config),
                        STOP_TEST_CALLS=str(self.calls), STOP_TEST_ROOT=str(ROOT),
                        PATH=f'{fake_bin}:{os.environ["PATH"]}')
        docker = fake_bin / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ['STOP_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(['docker', *args]) + '\\n')
if args[0] == 'ps':
    if os.environ.get('DOCKER_PS_ERROR'):
        sys.exit(1)
    if 'label=com.docker.compose.project.working_dir=' + os.environ['STOP_TEST_ROOT'] not in args:
        sys.exit('Unscoped Docker listing refused by test')
    print(os.environ.get('PROJECT_LIST', 'a1 postgres-dr-local\\nb2 postgres-dr-s3\\nc3 postgres-dr-replication\\nd4 unrelated-app\\ne5 postgres-dr-custom'))
elif args[0] == 'top':
    if args[2:] != ['-eo', 'pid,args']:
        sys.exit("Error response from daemon: Couldn't find PID field in ps output")
    if args[1] == os.environ.get('BUSY_CONTAINER'):
        print('PID COMMAND\\n42 ' + os.environ.get('BACKUP_COMMAND', 'pgbackrest --stanza=orders --type=full backup'))
    else:
        print('PID COMMAND\\n42 postgres -D /var/lib/postgresql/data')
elif args[0] != 'stop':
    sys.exit('Unexpected Docker mutation')
''')
        docker.chmod(0o755)
        systemctl = fake_bin / 'systemctl'
        systemctl.write_text('''#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ['STOP_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(['systemctl', *sys.argv[1:]]) + '\\n')
if os.environ.get('MANAGER_UNAVAILABLE'):
    sys.exit(1)
if sys.argv[1:3] == ['--user', 'show']:
    print(os.environ.get('JOB_STATE', 'inactive'))
elif sys.argv[1:4] != ['--user', 'disable', '--now']:
    sys.exit('Unexpected systemctl operation')
''')
        systemctl.chmod(0o755)

    def run_stop(self):
        return subprocess.run(['bash', str(ROOT / 'scripts/compose.sh'), '--stop-all'],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def recorded_calls(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def install_unit_markers(self):
        units = self.config / 'systemd/user'
        units.mkdir(parents=True)
        for name in ('postgres-dr-backup', 'postgres-dr-backup-health'):
            for suffix in ('service', 'timer'):
                (units / f'{name}.{suffix}').touch()

    def assert_no_stop(self):
        self.assertFalse(any(call[:2] == ['docker', 'stop'] for call in self.recorded_calls()))

    def test_stops_only_matching_project_containers_without_removing_data(self):
        result = self.run_stop()
        self.assertEqual(result.returncode, 0, result.stderr)
        stops = [call for call in self.recorded_calls() if call[:2] == ['docker', 'stop']]
        self.assertEqual(stops, [['docker', 'stop', '--timeout', '30', 'a1', 'b2', 'c3', 'e5']])

    def test_refuses_manual_backup_and_worker_process(self):
        for command in ('pgbackrest --stanza=orders --type=full backup',
                        'pgbackrest [backup:local-1]'):
            with self.subTest(command=command):
                self.env.update(BUSY_CONTAINER='a1', BACKUP_COMMAND=command)
                result = self.run_stop()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Backup is running', result.stderr)
                self.assert_no_stop()

    def test_refuses_running_scheduled_job_after_disabling_timers(self):
        self.install_unit_markers()
        self.env['JOB_STATE'] = 'activating'
        result = self.run_stop()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('still running', result.stderr)
        self.assertTrue(any(call[:4] == ['systemctl', '--user', 'disable', '--now']
                            for call in self.recorded_calls()))
        self.assert_no_stop()

    def test_refuses_when_installed_timers_cannot_be_disabled(self):
        self.install_unit_markers()
        self.env['MANAGER_UNAVAILABLE'] = '1'
        self.assertNotEqual(self.run_stop().returncode, 0)
        self.assert_no_stop()

    def test_docker_listing_failure_is_not_reported_as_empty(self):
        self.env['DOCKER_PS_ERROR'] = '1'
        result = self.run_stop()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('No running project containers', result.stdout)
        self.assert_no_stop()

    def test_no_running_containers_is_a_successful_noop(self):
        self.env['PROJECT_LIST'] = ''
        result = self.run_stop()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No running project containers', result.stdout)
        self.assert_no_stop()


if __name__ == '__main__':
    unittest.main()
