"""Verify automatic failover and quorum behavior in a disposable Patroni cluster."""

from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
NODES = ('pg1', 'pg2')


class Cluster:
    def __init__(self, directory: str):
        self.project = f'postgres-dr-patroni-test-{int(time.time())}-{os.getpid()}'
        self.directory = Path(directory)
        self.env = dict(os.environ, PGDR_PATRONI_PROJECT=self.project,
                        PGDR_PATRONI_DIR=directory, PGDR_PATRONI_PORT='0')
        self.command = ['bash', str(ROOT / 'scripts/compose.sh'), '--patroni']

    def compose(self, *args: str, check: bool = True, timeout: int = 240):
        result = subprocess.run([*self.command, *args], cwd=ROOT, env=self.env,
                                text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(f'Compose {args[0]} failed:\n{result.stdout[-2000:]}\n{result.stderr[-4000:]}')
        return result

    def cleanup(self):
        result = self.compose('--profile', 'restore', '--profile', 'tools',
                              'down', '--volumes', '--remove-orphans', check=False)
        if result.returncode:
            raise RuntimeError(f'Cleanup failed for {self.project}; private files retained at {self.directory}')
        for resource in ('container', 'volume', 'network'):
            remaining = subprocess.check_output(['docker', resource, 'ls', '-q', '--filter',
                                                 f'label=com.docker.compose.project={self.project}'],
                                                text=True, timeout=15)
            if remaining.strip():
                raise RuntimeError(f'Cleanup left {resource} resources for {self.project}; inspect before retrying')

    def sql_result(self, node: str, query: str):
        return self.compose('exec', '-T', '--user', 'postgres',
                            '-e', 'PGOPTIONS=-c statement_timeout=3000 -c lock_timeout=1000', node,
                            'psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate',
                            '-U', 'postgres', '-d', 'orders', '-c', query, check=False, timeout=15)

    def sql(self, node: str, query: str) -> str:
        result = self.sql_result(node, query)
        if result.returncode:
            raise RuntimeError(f'SQL on {node} failed: {result.stderr.strip()}')
        return result.stdout.strip()

    def endpoint_result(self, query: str, *options: str, mounts: tuple[str, ...] = ()):
        arguments = ['run', '--rm', '--no-deps', '-T', '--user', f'{os.getuid()}:{os.getgid()}']
        for mount in mounts:
            arguments.extend(['--volume', mount])
        return self.compose(*arguments, 'client', '-Atq', '-c', query, *options, check=False, timeout=25)

    def endpoint_sql(self, query: str) -> str:
        result = self.endpoint_result(query)
        if result.returncode:
            raise RuntimeError(f'HAProxy SQL failed: {result.stderr.strip()}')
        return result.stdout.strip()

    def operation(self, script: str, *arguments: str, check: bool = True, **settings):
        print(f'Running {script} {" ".join(arguments)}', flush=True)
        result = subprocess.run(['bash', str(ROOT / 'scripts' / script), *arguments], cwd=ROOT,
                                env=dict(self.env, PGDR_REPOSITORY='patroni', **settings),
                                text=True, capture_output=True, timeout=240)
        if check and result.returncode:
            raise RuntimeError(f'{script} {arguments} failed:\n{result.stdout[-2000:]}\n{result.stderr[-5000:]}')
        return result

    def dynamic_config(self, node: str, patch=None) -> dict:
        code = '''
import base64, json, ssl, sys
from urllib.request import Request, urlopen
from patroni_config import CONFIG, TLS
auth=json.loads(CONFIG.read_text())['restapi']['authentication']
token=base64.b64encode((auth['username']+':'+auth['password']).encode()).decode()
patch=json.loads(sys.argv[1])
request=Request('https://localhost:8008/config',
    data=None if patch is None else json.dumps(patch).encode(),
    method='GET' if patch is None else 'PATCH',
    headers={'Content-Type':'application/json', 'Authorization':'Basic '+token})
with urlopen(request, context=ssl.create_default_context(cafile=TLS+'/ca.crt'), timeout=10) as response:
    print(json.dumps(json.load(response)))'''
        result = self.compose('exec', '-T', '--user', 'postgres', node, 'python3', '-c',
                              'import sys; sys.path.insert(0, "/opt")\n' + code, json.dumps(patch))
        return json.loads(result.stdout)

    def repository_digest(self) -> str:
        result = self.compose('run', '--rm', '--no-deps', '-T', '--entrypoint', 'bash',
                              'repository', '-c', 'find /var/lib/pgbackrest -type f -exec sha256sum {} + | sort')
        return hashlib.sha256(result.stdout.encode()).hexdigest()

    def inspect(self, node: str) -> dict:
        return json.loads(subprocess.check_output(['docker', 'inspect', self.container(node)], text=True))[0]

    def address(self, node: str) -> str:
        networks = self.inspect(node)['NetworkSettings']['Networks']
        return networks[f'{self.project}_patroni']['IPAddress']

    def endpoint_is_primary(self, node: str) -> bool:
        result = self.endpoint_sql("SELECT pg_is_in_recovery(), inet_server_addr(), "
                                   "(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid())")
        return result == f'f|{self.address(node)}|t'

    def container(self, node: str) -> str:
        return self.compose('ps', '--all', '--quiet', node).stdout.strip()

    def running(self, node: str) -> bool:
        container = self.container(node)
        if not container:
            return False
        result = subprocess.run(['docker', 'inspect', container, '--format', '{{.State.Running}}'],
                                check=True, text=True, capture_output=True, timeout=10)
        return result.stdout.strip() == 'true'

    def members(self) -> list:
        node = next(node for node in NODES if self.running(node))
        result = self.compose('exec', '-T', '--user', 'postgres', node, 'patronictl',
                              '-c', '/var/lib/postgresql/patroni/patroni.json', 'list', '--format=json', timeout=20)
        return json.loads(result.stdout)

    def leader(self) -> str:
        leaders = [m['Member'] for m in self.members() if m['Role'] == 'Leader']
        if len(leaders) != 1:
            raise RuntimeError(f'Expected one Patroni leader, found {leaders}')
        return leaders[0]

    def probe(self, node: str, endpoint: str) -> bool:
        result = self.compose('exec', '-T', node, 'python3', '/opt/patroni_config.py',
                              'probe', endpoint, check=False, timeout=10)
        if result.returncode not in (0, 1):
            raise RuntimeError(f'Unexpected HTTPS failure on {node}: {result.stderr.strip()}')
        return result.returncode == 0

    def healthy(self) -> bool:
        members = self.members()
        return (len(members) == 2
                and sum(m['Role'] == 'Leader' and m['State'] == 'running' for m in members) == 1
                and sum(m['Role'] == 'Replica' and m['State'] == 'streaming' for m in members) == 1)

    def compare(self) -> bool:
        records = [self.sql(node, 'COPY (SELECT * FROM orders ORDER BY reference) TO STDOUT WITH CSV')
                   for node in NODES]
        return records[0] == records[1]

    def not_writable(self, node: str) -> bool:
        result = self.sql_result(node, 'SELECT pg_is_in_recovery()')
        if result.returncode == 0:
            if result.stdout.strip() not in ('t', 'f'):
                raise RuntimeError(f'Unexpected recovery state on {node}')
            return result.stdout.strip() == 't'
        # Connection/authentication failures alone do not establish demotion.
        status = self.compose('exec', '-T', '--user', 'postgres', node, 'pg_ctl',
                              '-D', '/var/lib/postgresql/data/pgdata', 'status', check=False)
        if status.returncode != 3:
            raise RuntimeError(f'Cannot establish that PostgreSQL on {node} stopped or became read-only')
        return True

    def acknowledge(self, first: int, count: int) -> list[str]:
        refs = []
        journal = self.directory / 'acknowledgments.jsonl'
        with journal.open('a') as out:
            for n in range(first, first + count):
                reference = f'patroni-workload-{n:03d}'
                observed = self.endpoint_sql(f"INSERT INTO orders (reference, amount_cents) VALUES ('{reference}', {n * 100}) RETURNING reference")
                if observed != reference:
                    raise RuntimeError('Unexpected insert acknowledgment')
                refs.append(reference)
                out.write(json.dumps({'reference': reference, 'amount_cents': n * 100, 'acknowledged': True,
                                      'acknowledged_utc': datetime.now(timezone.utc).isoformat()}) + '\n')
                out.flush()
                os.fsync(out.fileno())
        return refs


def wait_for(description, predicate, timeout=120):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                print(f'PASS: {description}', flush=True)
                return
        except (RuntimeError, subprocess.SubprocessError, ValueError, StopIteration) as error:
            last_error = error
        time.sleep(1)
    raise RuntimeError(f'Timed out: {description}; last error: {last_error}')


def security_checks(cluster: Cluster, source: str, replica: str):
    result = cluster.sql_result(replica, "INSERT INTO orders (reference, amount_cents) VALUES ('must-fail', 1)")
    assert result.returncode != 0 and '25006' in result.stderr, result.stderr
    assert cluster.sql(source, "SELECT count(*) FROM pg_stat_replication r JOIN pg_stat_ssl s USING (pid) WHERE s.ssl AND r.state='streaming'") == '1'
    assert cluster.sql(replica, "SELECT current_setting('primary_conninfo') ~ 'sslmode=verify-full'") == 't'
    code = '''
import json, ssl
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
ca='/var/lib/postgresql/patroni/tls/ca.crt'
context=ssl.create_default_context(cafile=ca)
try:
    urlopen(Request('https://localhost:8008/config', data=b'{}', method='PATCH',
                    headers={'Content-Type':'application/json'}), context=context, timeout=3)
except HTTPError as error:
    assert error.code == 401, error.code
else:
    raise AssertionError('Unauthenticated Patroni configuration change accepted')
client=ssl.create_default_context(cafile=ca)
client.load_cert_chain('/var/lib/postgresql/patroni/tls/etcd-client.crt', '/var/lib/postgresql/patroni/tls/etcd-client.key')
with urlopen('https://etcd1:2379/version', context=client, timeout=3) as response:
    assert json.load(response)['etcdserver'].startswith('3.6.')
try:
    urlopen('https://etcd1:2379/version', context=context, timeout=3)
except URLError as error:
    assert isinstance(error.reason, ssl.SSLError), type(error.reason)
except ssl.SSLError:
    pass
else:
    raise AssertionError('etcd accepted a request without a client certificate')
'''
    cluster.compose('exec', '-T', source, 'python3', '-c', code)
    for node in (*NODES, 'etcd1', 'etcd2', 'etcd3'):
        data = json.loads(subprocess.check_output(['docker', 'inspect', cluster.container(node)], text=True))[0]
        assert not data['HostConfig']['PortBindings'], node
        assert all('PASSWORD' not in entry.split('=', 1)[0] for entry in data['Config']['Env']), node
        keys = {Path(mount['Source']).name for mount in data['Mounts'] if mount['Source'].endswith('.key')}
        assert keys == ({f'{node}.key', 'patroni.key'} if node in NODES else {f'{node}.key'}), (node, keys)
    proxy = cluster.inspect('haproxy')
    bindings = proxy['NetworkSettings']['Ports']['5432/tcp']
    assert bindings and all(binding['HostIp'] == '127.0.0.1' for binding in bindings), bindings
    assert not any(Path(mount['Source']).suffix == '.key' for mount in proxy['Mounts'])
    assert not any('password' in mount['Destination'] for mount in proxy['Mounts'])
    # Exercise the actual published loopback port without exposing credentials.
    context = ssl.create_default_context(cafile=str(cluster.directory / 'tls/ca.crt'))
    with socket.create_connection(('127.0.0.1', int(bindings[0]['HostPort'])), timeout=5) as connection:
        connection.sendall(struct.pack('!II', 8, 80877103))  # PostgreSQL SSLRequest
        assert connection.recv(1) == b'S'
        with context.wrap_socket(connection, server_hostname='localhost') as secure:
            assert secure.cipher()
    failures = (
        (('-d', 'dbname=orders sslmode=disable'), 'no encryption'),
        (('-h', 'wrong-name.invalid', '-d', f'dbname=orders hostaddr={cluster.address("haproxy")}'), 'does not match host name'),
    )
    for options, expected in failures:
        result = cluster.endpoint_result('SELECT 1', *options)
        assert result.returncode != 0 and expected in result.stderr, result.stderr
    result = cluster.endpoint_result('SELECT 1', '-d', 'dbname=orders sslrootcert=/tmp/untrusted.crt',
                                     mounts=(f'{cluster.directory}/tls/etcd1.crt:/tmp/untrusted.crt:ro',))
    assert result.returncode != 0 and 'certificate verify failed' in result.stderr, result.stderr


def verify_proxy_api_identity(cluster: Cluster):
    """A valid HTTPS check routes SQL; wrong CA or server identity cannot route it."""
    config = (ROOT / 'haproxy/patroni.cfg').read_text()
    untrusted = cluster.directory / 'untrusted.crt'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=untrusted', '-keyout', str(cluster.directory / 'untrusted.key'),
                    '-out', str(untrusted)], check=True, capture_output=True, timeout=15)
    variants = (
        ('verified', config, cluster.directory / 'tls/ca.crt', True),
        ('wrong-host', config.replace('verifyhost pg1', 'verifyhost wrong-name.invalid')
         .replace('verifyhost pg2', 'verifyhost wrong-name.invalid'), cluster.directory / 'tls/ca.crt', False),
        ('untrusted-ca', config, untrusted, False),
    )
    for label, contents, ca, allowed in variants:
        path = cluster.directory / f'{label}.cfg'
        path.write_text(contents)
        name = f'{cluster.project}-check-{label}'
        try:
            subprocess.run(['docker', 'run', '--detach', '--name', name,
                            '--label', f'com.docker.compose.project={cluster.project}',
                            '--network', f'{cluster.project}_patroni',
                            '--user', f'{os.getuid()}:{os.getgid()}',
                            '--mount', f'type=bind,src={path},dst=/usr/local/etc/haproxy/haproxy.cfg,readonly',
                            '--mount', f'type=bind,src={ca},dst=/run/secrets/ca.crt,readonly',
                            cluster.inspect('haproxy')['Config']['Image']],
                           check=True, capture_output=True, text=True, timeout=20)
            data = json.loads(subprocess.check_output(['docker', 'inspect', name], text=True))[0]
            address = data['NetworkSettings']['Networks'][f'{cluster.project}_patroni']['IPAddress']

            def query():
                return cluster.endpoint_result('SELECT pg_is_in_recovery()', '-d', f'dbname=orders hostaddr={address}')

            if allowed:
                wait_for('verified HTTPS role checks admit primary SQL',
                         lambda: (result := query()).returncode == 0 and result.stdout.strip() == 'f', timeout=45)
            else:
                wait_for(f'{label} HTTPS role checks report TLS failure',
                         lambda: 'Layer6 invalid response' in subprocess.check_output(
                             ['docker', 'logs', name], text=True, stderr=subprocess.STDOUT), timeout=30)
                assert query().returncode != 0, label
                print(f'PASS: {label} role checks cannot route SQL', flush=True)
        except BaseException:
            logs = subprocess.run(['docker', 'logs', name], text=True, capture_output=True, timeout=10)
            print(f'HAProxy fixture {label}:\n{logs.stdout}\n{logs.stderr}', flush=True)
            raise
        finally:
            subprocess.run(['docker', 'rm', '--force', name], check=True, capture_output=True, timeout=20)


def open_endpoint_session(cluster: Cluster):
    command = [*cluster.command, 'run', '--rm', '--no-deps', '-T',
               '--name', f'{cluster.project}-session', '--user', f'{os.getuid()}:{os.getgid()}',
               'client', '-Atq']
    session = subprocess.Popen(command, cwd=ROOT, env=cluster.env, text=True,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if session.stdin is None or session.stdout is None:
        raise RuntimeError('Cannot open endpoint session pipes')
    session.stdin.write("SELECT 'endpoint-session-ready';\nSELECT pg_sleep(120);\n")
    session.stdin.flush()
    if not select.select([session.stdout], [], [], 25)[0] or session.stdout.readline().strip() != 'endpoint-session-ready':
        session.terminate()
        session.wait(timeout=10)
        raise RuntimeError('Persistent endpoint SQL session did not become ready')
    return session


def exercise(cluster: Cluster) -> dict:
    print('[1/8] Start isolated Patroni and three-member etcd cluster', flush=True)
    subprocess.run(['bash', str(ROOT / 'scripts/patroni.sh'), 'up'], cwd=ROOT, env=cluster.env, check=True)
    wait_for('one primary and one streaming replica', cluster.healthy)
    source = cluster.leader()
    replica = next(node for node in NODES if node != source)
    wait_for('HAProxy routes verified TLS to the elected primary', lambda: cluster.endpoint_is_primary(source))
    acknowledged = cluster.acknowledge(1, 20)
    wait_for('20 exact orders reach the replica', cluster.compare)

    print('[2/8] Verify replication TLS, protected API and mutual TLS to etcd', flush=True)
    security_checks(cluster, source, replica)
    verify_proxy_api_identity(cluster)

    print('[3/8] Keep writes available with one etcd member stopped', flush=True)
    cluster.compose('stop', 'etcd3')
    cluster.sql(source, "INSERT INTO orders (reference, amount_cents) VALUES ('patroni-quorum-probe', 1); DELETE FROM orders WHERE reference='patroni-quorum-probe'")
    wait_for('two-member quorum retains the leader and replicates writes', lambda: cluster.leader() == source and cluster.compare())
    cluster.compose('start', 'etcd3')

    print('[4/8] Isolate replica, acknowledge five writes, and crash the leader', flush=True)
    network = f'{cluster.project}_patroni'
    replica_container = cluster.container(replica)
    subprocess.run(['docker', 'network', 'disconnect', network, replica_container], check=True)
    acknowledged += cluster.acknowledge(21, 5)
    assert cluster.sql(replica, 'SELECT count(*) FROM orders') == '20'
    session = open_endpoint_session(cluster)
    fault_started = time.monotonic()
    cluster.compose('kill', '--signal', 'SIGKILL', source)
    session.communicate(timeout=20)
    assert session.returncode != 0, 'Open SQL session unexpectedly survived a leader crash'
    print('PASS: old SQL connection breaks; reconnect is required', flush=True)
    subprocess.run(['docker', 'network', 'connect', '--alias', replica, network, replica_container], check=True)
    wait_for('replica acquires the leader lease and accepts writes', lambda: cluster.probe(replica, 'primary')
             and cluster.sql(replica, 'SELECT pg_is_in_recovery()') == 'f')
    failover_seconds = time.monotonic() - fault_started
    wait_for('same HAProxy address routes a new TLS connection to the promoted primary',
             lambda: cluster.endpoint_is_primary(replica))
    endpoint_recovery_seconds = time.monotonic() - fault_started
    recovered = cluster.sql(replica, "SELECT reference FROM orders WHERE reference LIKE 'patroni-workload-%' ORDER BY reference").splitlines()
    expected = '\n'.join(f'patroni-workload-{n:03d}|{n * 100}' for n in range(1, 21))
    assert cluster.sql(replica, "SELECT reference, amount_cents FROM orders ORDER BY reference") == expected
    lost = sorted(set(acknowledged) - set(recovered))
    assert len(recovered) == 20 and lost == [f'patroni-workload-{n:03d}' for n in range(21, 26)], (recovered, lost)
    cluster.endpoint_sql("INSERT INTO orders (reference, amount_cents) VALUES ('patroni-after-failover', 2600)")

    print('[5/8] Rejoin the crashed former leader without manual promotion or data deletion', flush=True)
    cluster.compose('start', source)
    wait_for('former leader returns as a streaming replica', cluster.healthy)
    wait_for('both nodes contain the same 21 surviving orders', cluster.compare)
    assert cluster.sql(source, 'SELECT pg_is_in_recovery()') == 't'
    assert cluster.sql(source, "SELECT count(*) FROM orders WHERE reference IN ('patroni-workload-021','patroni-workload-022','patroni-workload-023','patroni-workload-024','patroni-workload-025')") == '0'
    security_checks(cluster, replica, source)

    print('[6/8] Remove etcd quorum and confirm that no PostgreSQL node stays writable', flush=True)
    assert cluster.sql(replica, 'SELECT pg_is_in_recovery()') == 'f'
    cluster.compose('stop', 'etcd2', 'etcd3')
    wait_for('both nodes are stopped or read-only after quorum loss', lambda: all(cluster.not_writable(node) for node in NODES))
    wait_for('neither API advertises a primary', lambda: all(not cluster.probe(node, 'primary') for node in NODES))
    wait_for('HAProxy refuses SQL connections without a confirmed primary',
             lambda: cluster.endpoint_result('SELECT 1').returncode != 0)

    print('[7/8] Restore quorum, resume replication and accept a new write', flush=True)
    cluster.compose('start', 'etcd2', 'etcd3')
    wait_for('leader election and streaming recover with quorum', cluster.healthy)
    current = cluster.leader()
    wait_for('same HAProxy endpoint recovers after quorum restoration', lambda: cluster.endpoint_is_primary(current))
    cluster.endpoint_sql("INSERT INTO orders (reference, amount_cents) VALUES ('patroni-after-quorum', 2700)")
    wait_for('22 exact orders reach both nodes', cluster.compare)

    print('[8/8] Recreate containers with retained PostgreSQL and DCS data', flush=True)
    cluster.compose('down')
    subprocess.run(['bash', str(ROOT / 'scripts/patroni.sh'), 'up'], cwd=ROOT, env=cluster.env, check=True)
    wait_for('retained cluster has one primary and one streaming replica', cluster.healthy)
    wait_for('retained databases contain identical rows', cluster.compare)
    assert cluster.sql(cluster.leader(), 'SELECT count(*) FROM orders') == '22'
    current = cluster.leader()
    wait_for('HAProxy endpoint recovers with retained state', lambda: cluster.endpoint_is_primary(current))
    security_checks(cluster, current, next(node for node in NODES if node != current))
    for role, expected_role in (('primary-psql', 'f'), ('standby-psql', 't')):
        result = subprocess.run(['bash', str(ROOT / 'scripts/patroni.sh'), role, '-Atc',
                                 'SELECT pg_is_in_recovery()'], cwd=ROOT, env=cluster.env,
                                text=True, capture_output=True, check=True, timeout=20)
        assert result.stdout.strip() == expected_role, result.stdout
    print('PASS: recreated TLS/access controls and role-aware SQL helpers', flush=True)
    return {'schema_version': 1, 'status': 'verified', 'project': cluster.project,
            'scenario': 'patroni_automatic_failover', 'acknowledged_orders': len(acknowledged),
            'recovered_orders': len(recovered), 'lost_orders': lost,
            'observed_failover_seconds': round(failover_seconds, 3),
            'observed_endpoint_recovery_seconds': round(endpoint_recovery_seconds, 3),
            'endpoint': 'haproxy:5432', 'endpoint_tls': 'verify-full',
            'endpoint_measurement': 'leader kill through first verified SQL connection via HAProxy; includes client startup and replica network reconnection',
            'failover_measurement': 'leader container kill through reachable promoted primary; includes replica network reconnection',
            'final_order_count': 22}


def exercise_backup(cluster: Cluster) -> dict:
    print('[1/8] Upgrade existing DCS archive settings while retaining PostgreSQL data', flush=True)
    cluster.operation('patroni.sh', 'up')
    wait_for('one primary and one streaming replica', cluster.healthy)
    source = cluster.leader()
    cluster.endpoint_sql("INSERT INTO orders (reference, amount_cents) VALUES ('patroni-dr-001',1500),('patroni-dr-002',2500)")
    wait_for('initial orders reach both nodes', cluster.compare)
    original_rows = cluster.sql(source, 'COPY (SELECT * FROM orders ORDER BY reference) TO STDOUT WITH CSV')
    system_id = cluster.sql(source, 'SELECT system_identifier FROM pg_control_system()')
    # Recreate the archive-disabled DCS settings of v0.14.0 on this disposable cluster.
    cluster.dynamic_config(source, {'postgresql': {'parameters': {
        'archive_mode': 'off', 'archive_command': '', 'archive_timeout': '0'}}})
    cluster.compose('down')
    cluster.operation('patroni.sh', 'up')
    wait_for('archive-disabled retained cluster is ready', cluster.healthy)
    source = cluster.leader()
    assert cluster.sql(source, 'SHOW archive_mode') == 'off'
    before = cluster.dynamic_config(source)['postgresql']['parameters']
    cluster.operation('patroni.sh', 'backup-configure')
    after = cluster.dynamic_config(source)['postgresql']['parameters']
    changed = {'archive_mode', 'archive_command', 'archive_timeout'}
    assert {k: v for k, v in before.items() if k not in changed} == {k: v for k, v in after.items() if k not in changed}
    cluster.compose('down')
    cluster.operation('patroni.sh', 'up')
    wait_for('retained cluster starts with archiving enabled', cluster.healthy)
    source = cluster.leader()
    for node in NODES:
        assert cluster.sql(node, 'SHOW archive_mode') == 'on'
        assert cluster.sql(node, 'SELECT system_identifier FROM pg_control_system()') == system_id
        assert cluster.sql(node, 'COPY (SELECT * FROM orders ORDER BY reference) TO STDOUT WITH CSV') == original_rows
    print('PASS: DCS archive upgrade preserves unrelated settings, system identity and exact rows', flush=True)

    print('[2/8] Create and verify a full backup on the current primary', flush=True)
    cluster.operation('backup.sh', 'init')
    empty = cluster.operation('backup.sh', 'verify', check=False)
    assert empty.returncode != 0 and 'completed backup' in empty.stderr, empty.stdout + empty.stderr
    cluster.operation('backup.sh', 'full')
    info = json.loads(cluster.compose('run', '--rm', '--no-deps', '-T', 'repository',
                                      '--log-level-console=off', '--output=json', 'info').stdout)[0]
    assert info['status']['code'] == 0 and len(info['backup']) == 1
    backup = info['backup'][0]
    label = backup['label']
    backup_timeline = int(backup['archive']['start'][:8], 16)
    print(f'PASS: full backup {label} on timeline {backup_timeline}', flush=True)

    print('[3/8] Promote the replica and archive new-timeline writes', flush=True)
    replica = next(node for node in NODES if node != source)
    cluster.compose('kill', '--signal', 'SIGKILL', source)
    wait_for('replica is promoted', lambda: cluster.probe(replica, 'primary'))
    wait_for('HAProxy routes the promoted primary', lambda: cluster.endpoint_is_primary(replica))
    cluster.endpoint_sql("INSERT INTO orders (reference, amount_cents) VALUES ('patroni-dr-after-failover',3500)")
    timeline = int(cluster.sql(replica, 'SELECT left(pg_walfile_name(pg_current_wal_lsn()),8)'), 16)
    assert timeline > backup_timeline
    expected_rows = cluster.sql(replica, 'COPY (SELECT * FROM orders ORDER BY reference) TO STDOUT WITH CSV')
    target = cluster.sql(replica, "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US') || '+00:00'")
    print(f'PASS: new write on timeline {timeline}; recovery target {target}', flush=True)
    cluster.operation('backup.sh', 'full')
    promoted_info = json.loads(cluster.compose('run', '--rm', '--no-deps', '-T', 'repository',
                                               '--log-level-console=off', '--output=json', 'info').stdout)[0]
    assert len(promoted_info['backup']) == 2
    promoted_backup = next(item for item in promoted_info['backup'] if item['label'] != label)
    assert int(promoted_backup['archive']['start'][:8], 16) == timeline
    print(f'PASS: new primary created full backup {promoted_backup["label"]}; recovery still selects {label}', flush=True)

    print('[4/8] Delete an order, add a late order, and flush the archive', flush=True)
    cluster.endpoint_sql("DELETE FROM orders WHERE reference='patroni-dr-002'")
    cluster.endpoint_sql("INSERT INTO orders (reference, amount_cents) VALUES ('patroni-dr-too-late',4500)")
    cluster.operation('backup.sh', 'check')
    assert cluster.sql(replica, "SELECT count(*) FROM orders WHERE reference='patroni-dr-002'") == '0'
    cluster.compose('start', source)
    wait_for('former leader rejoins with the deletion', cluster.healthy)
    wait_for('both live nodes contain the deletion and late order', cluster.compare)
    cluster.operation('backup.sh', 'check')

    print('[5/8] Stop the source cluster and inspect backups without a database', flush=True)
    cluster.compose('down')
    assert all(not cluster.container(node) for node in NODES)
    offline = cluster.operation('backup.sh', 'info')
    assert label in offline.stdout and promoted_backup['label'] in offline.stdout
    cluster.operation('backup.sh', 'verify')
    digest = cluster.repository_digest()
    settings = {'BACKUP_LABEL': label, 'RECOVERY_TIME': target,
                'RECOVERY_TIMELINE': str(timeline), 'RESTORE_WAIT_SECONDS': '30'}
    print('PASS: backup metadata and verification work with all live services removed', flush=True)

    print('[6/8] Reject an unreachable time and refuse to overwrite the failed target', flush=True)
    invalid = cluster.operation('restore.sh', 'time', check=False, **dict(settings, RECOVERY_TIMELINE='0'))
    assert invalid.returncode != 0 and 'RECOVERY_TIMELINE' in invalid.stderr
    future = datetime.fromisoformat(target) + timedelta(days=1)
    future_time = future.strftime('%Y-%m-%d %H:%M:%S.%f+00:00')
    failed = cluster.operation('restore.sh', 'time', check=False, **dict(settings, RECOVERY_TIME=future_time))
    assert failed.returncode != 0 and 'recovery ended before configured recovery target was reached' in failed.stderr, failed.stderr[-4000:]
    existing = cluster.operation('restore.sh', 'time', check=False, **settings)
    assert existing.returncode != 0 and 'Restore container already exists' in existing.stderr
    cluster.compose('rm', '--stop', '--force', 'restore')
    nonempty = cluster.operation('restore.sh', 'time', check=False, **settings)
    assert nonempty.returncode != 0 and 'Restore target is not empty' in nonempty.stdout + nonempty.stderr
    subprocess.run(['docker', 'volume', 'rm', f'{cluster.project}_pgrestore'], check=True, capture_output=True, timeout=20)
    print('PASS: invalid timeline, unreachable target, existing container and nonempty volume are rejected', flush=True)

    print('[7/8] Restore the pre-failover backup onto the new timeline before deletion', flush=True)
    cluster.operation('restore.sh', 'time', **settings)
    actual = cluster.sql('restore', 'COPY (SELECT * FROM orders ORDER BY reference) TO STDOUT WITH CSV')
    assert actual == expected_rows, (actual, expected_rows)
    assert cluster.sql('restore', 'SELECT pg_is_in_recovery()') == 'f'
    assert cluster.sql('restore', 'SHOW archive_mode') == 'off'
    data = cluster.inspect('restore')
    assert data['HostConfig']['NetworkMode'] == 'none' and not data['HostConfig']['PortBindings']
    mounts = {m['Destination']: m for m in data['Mounts']}
    assert not mounts['/var/lib/pgbackrest']['RW']
    assert mounts['/var/lib/postgresql/data']['Name'] == f'{cluster.project}_pgrestore'
    assert all(m.get('Name') not in (f'{cluster.project}_pg1_data', f'{cluster.project}_pg2_data') for m in data['Mounts'])
    assert not any(m['Destination'].startswith('/run/secrets') for m in data['Mounts'])
    assert cluster.repository_digest() == digest
    cluster.sql('restore', "INSERT INTO orders (reference,amount_cents) VALUES ('patroni-dr-restored-write',5500)")
    print('PASS: three exact orders recovered, including the deleted order and post-failover write; late order excluded', flush=True)

    print('[8/8] Recreate only the restore container and preserve restored writes', flush=True)
    cluster.compose('rm', '--stop', '--force', 'restore')
    cluster.operation('restore.sh', 'start')
    assert cluster.sql('restore', 'SELECT count(*) FROM orders') == '4'
    assert cluster.sql('restore', 'SHOW archive_mode') == 'off'
    assert cluster.repository_digest() == digest
    return {'schema_version': 1, 'status': 'verified', 'project': cluster.project,
            'scenario': 'patroni_cross_timeline_pitr', 'backup_label': label,
            'post_failover_backup_label': promoted_backup['label'],
            'post_failover_backup_timeline': timeline,
            'backup_timeline': backup_timeline, 'recovery_timeline': timeline,
            'recovery_time_utc': target, 'recovered_orders': 3, 'final_order_count': 4,
            'source_system_identifier': system_id, 'repository_sha256': digest,
            'archive_dcs_upgrade': 'verified', 'unreachable_target_rejected': True,
            'source_services_removed_during_restore': True}


def main():
    if sys.argv[1:] not in ([], ['--backup']):
        raise SystemExit('Usage: patroni_acceptance.py [--backup]')
    backup_mode = sys.argv[1:] == ['--backup']
    directory = tempfile.mkdtemp(prefix='pgdr-patroni-')
    cluster = Cluster(directory)
    try:
        report = exercise_backup(cluster) if backup_mode else exercise(cluster)
        suffix = 'patroni-backup' if backup_mode else 'patroni'
        output = ROOT / '.local/reports' / f'{cluster.project}-{suffix}.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
        journal = cluster.directory / 'acknowledgments.jsonl'
        if journal.exists():
            output.with_suffix('.jsonl').write_bytes(journal.read_bytes())
    except BaseException:
        print(cluster.compose('logs', '--no-color', '--tail=50', check=False).stdout, flush=True)
        raise
    finally:
        cluster.cleanup()
        shutil.rmtree(directory)
    print(f'PASS: {report["scenario"]}; report: {output}', flush=True)


if __name__ == '__main__':
    main()
