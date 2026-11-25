"""Regress startup gates without contacting Docker's daemon or AWS."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def clean_environment():
    return {key: value for key, value in os.environ.items()
            if not key.startswith(('PGDR_', 'COMPOSE_', 'BASH_FUNC_'))
            and key not in ('BASH_ENV', 'ENV')}


class ComposeReadinessTests(unittest.TestCase):
    def config(self, runtime):
        result = subprocess.run(['bash', str(ROOT / 'scripts/compose.sh'), runtime,
                                 'config', '--format', 'json'], env=clean_environment(),
                                check=True, capture_output=True, text=True, timeout=15)
        return json.loads(result.stdout)

    def test_replication_rejects_socket_only_temporary_initdb_server(self):
        check = self.config('--replication')['services']['primary']['healthcheck']['test']
        self.assertEqual(check[0], 'CMD-SHELL')
        # The official image's temporary server listens only on Unix sockets.
        # Execute the production healthcheck with the two readiness states.
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'pg_isready'
            binary.write_text('#!/bin/bash\n'
                              'if [[ " $* " == *" -h 127.0.0.1 "* ]]; then\n'
                              '  exit "$TEST_TCP_STATUS"\n'
                              'fi\nexit 0\n')
            binary.chmod(0o755)
            for tcp_status in (1, 0):
                result = subprocess.run(['bash', '-c', check[1]], env=dict(
                    clean_environment(), PATH=f'{directory}:{os.environ["PATH"]}',
                    TEST_TCP_STATUS=str(tcp_status)), timeout=5)
                self.assertEqual(result.returncode, tcp_status)

    def test_patroni_services_can_start_before_their_peers_are_healthy(self):
        services = self.config('--patroni')['services']
        for service in ('pg1', 'pg2', 'haproxy'):
            with self.subTest(service=service):
                self.assertFalse(services[service].get('depends_on'))


class PatroniStartupTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='pgdr startup ')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('patroni.sh', 'compose.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
        # Setup is outside this test's scope; never load real credentials.
        (scripts / 'setup.sh').write_text('#!/bin/bash\nexit 0\n')
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text(f'#!{sys.executable}\n' + '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
failed = os.environ.get('TEST_FAILED', '').split(',')
if args[0] == 'inspect':
    node = args[1]
    print('false unhealthy' if node in failed else 'true healthy')
elif args[0] == 'compose':
    args = args[args.index('--file') + 2:]
    if args[0] in ('build', 'up', 'logs'):
        pass
    elif args[0] == 'ps':
        if args[-1] in ('etcd1', 'etcd2', 'etcd3'):
            print(args[-1])
    elif args[0] == 'exec':
        node = args[args.index('python3') - 1]
        if node in failed:
            sys.exit(2)  # Unreachable API, rather than a healthy replica's 503.
        primaries = os.environ.get('TEST_PRIMARIES', 'pg1').split(',')
        sys.exit(0 if node in primaries else 1)
    elif args[0] == 'run' and 'client' in args:
        print(os.environ.get('TEST_SQL', 't'))
        sys.exit(int(os.environ.get('TEST_SQL_STATUS', '0')))
    else:
        sys.exit('Unexpected compose operation: ' + repr(args))
else:
    sys.exit('Unexpected Docker operation')
''')
        docker.chmod(0o755)
        self.calls = self.root / 'calls.jsonl'
        self.env = dict(clean_environment(), PATH=f'{binary}:{os.environ["PATH"]}',
                        TEST_CALLS=str(self.calls), PGDR_PATRONI_WAIT_SECONDS='5')

    def start(self, **settings):
        return subprocess.run(['bash', str(self.root / 'scripts/patroni.sh'), 'up'],
                              env=dict(self.env, **settings), text=True,
                              capture_output=True, timeout=10)

    def test_healthy_and_single_member_failures_allow_verified_sql(self):
        for failed, primary in (('', 'pg1'), ('etcd1', 'pg1'), ('etcd2', 'pg1'),
                                ('etcd3', 'pg1'), ('pg1', 'pg2'), ('pg2', 'pg1')):
            with self.subTest(failed=failed):
                result = self.start(TEST_FAILED=failed, TEST_PRIMARIES=primary)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('verified SQL through HAProxy', result.stdout)

    def test_quorum_leader_and_endpoint_failures_do_not_report_success(self):
        for settings in ({'TEST_FAILED': 'etcd2,etcd3'},
                         {'TEST_FAILED': 'pg1,pg2'},
                         {'TEST_PRIMARIES': ''},
                         {'TEST_PRIMARIES': 'pg1,pg2'},
                         {'TEST_SQL': 'f'}, {'TEST_SQL': ''}, {'TEST_SQL_STATUS': '1'}):
            with self.subTest(settings=settings):
                result = self.start(PGDR_PATRONI_WAIT_SECONDS='1', **settings)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('Patroni startup failed', result.stderr)
                calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
                self.assertFalse(any('down' in call or 'rm' in call for call in calls))

    def test_invalid_timeout_is_rejected_before_setup_or_docker(self):
        result = self.start(PGDR_PATRONI_WAIT_SECONDS='0')
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()
