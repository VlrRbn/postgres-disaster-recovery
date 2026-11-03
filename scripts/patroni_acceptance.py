"""Verify automatic failover and quorum behavior in a disposable Patroni cluster."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
NODES = ('pg1', 'pg2')


class Cluster:
    def __init__(self, directory: str):
        self.project = f'postgres-dr-patroni-test-{int(time.time())}-{os.getpid()}'
        self.directory = Path(directory)
        self.env = dict(os.environ, PGDR_PATRONI_PROJECT=self.project, PGDR_PATRONI_DIR=directory)
        self.command = ['bash', str(ROOT / 'scripts/compose.sh'), '--patroni']

    def compose(self, *args: str, check: bool = True, timeout: int = 240):
        result = subprocess.run([*self.command, *args], cwd=ROOT, env=self.env,
                                text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(f'Compose {args[0]} failed:\n{result.stdout[-2000:]}\n{result.stderr[-4000:]}')
        return result

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

    def acknowledge(self, node: str, first: int, count: int) -> list[str]:
        refs = []
        journal = self.directory / 'acknowledgments.jsonl'
        with journal.open('a') as out:
            for n in range(first, first + count):
                reference = f'patroni-workload-{n:03d}'
                observed = self.sql(node, f"INSERT INTO orders (reference, amount_cents) VALUES ('{reference}', {n * 100}) RETURNING reference")
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


def exercise(cluster: Cluster) -> dict:
    print('[1/8] Start isolated Patroni and three-member etcd cluster', flush=True)
    subprocess.run(['bash', str(ROOT / 'scripts/patroni.sh'), 'up'], cwd=ROOT, env=cluster.env, check=True)
    wait_for('one primary and one streaming replica', cluster.healthy)
    source = cluster.leader()
    replica = next(node for node in NODES if node != source)
    acknowledged = cluster.acknowledge(source, 1, 20)
    wait_for('20 exact orders reach the replica', cluster.compare)

    print('[2/8] Verify replication TLS, protected API and mutual TLS to etcd', flush=True)
    security_checks(cluster, source, replica)

    print('[3/8] Keep writes available with one etcd member stopped', flush=True)
    cluster.compose('stop', 'etcd3')
    cluster.sql(source, "INSERT INTO orders (reference, amount_cents) VALUES ('patroni-quorum-probe', 1); DELETE FROM orders WHERE reference='patroni-quorum-probe'")
    wait_for('two-member quorum retains the leader and replicates writes', lambda: cluster.leader() == source and cluster.compare())
    cluster.compose('start', 'etcd3')

    print('[4/8] Isolate replica, acknowledge five writes, and crash the leader', flush=True)
    network = f'{cluster.project}_patroni'
    replica_container = cluster.container(replica)
    subprocess.run(['docker', 'network', 'disconnect', network, replica_container], check=True)
    acknowledged += cluster.acknowledge(source, 21, 5)
    assert cluster.sql(replica, 'SELECT count(*) FROM orders') == '20'
    fault_started = time.monotonic()
    cluster.compose('kill', '--signal', 'SIGKILL', source)
    subprocess.run(['docker', 'network', 'connect', '--alias', replica, network, replica_container], check=True)
    wait_for('replica acquires the leader lease and accepts writes', lambda: cluster.probe(replica, 'primary')
             and cluster.sql(replica, 'SELECT pg_is_in_recovery()') == 'f')
    failover_seconds = time.monotonic() - fault_started
    recovered = cluster.sql(replica, "SELECT reference FROM orders WHERE reference LIKE 'patroni-workload-%' ORDER BY reference").splitlines()
    expected = '\n'.join(f'patroni-workload-{n:03d}|{n * 100}' for n in range(1, 21))
    assert cluster.sql(replica, "SELECT reference, amount_cents FROM orders ORDER BY reference") == expected
    lost = sorted(set(acknowledged) - set(recovered))
    assert len(recovered) == 20 and lost == [f'patroni-workload-{n:03d}' for n in range(21, 26)], (recovered, lost)
    cluster.sql(replica, "INSERT INTO orders (reference, amount_cents) VALUES ('patroni-after-failover', 2600)")

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

    print('[7/8] Restore quorum, resume replication and accept a new write', flush=True)
    cluster.compose('start', 'etcd2', 'etcd3')
    wait_for('leader election and streaming recover with quorum', cluster.healthy)
    current = cluster.leader()
    cluster.sql(current, "INSERT INTO orders (reference, amount_cents) VALUES ('patroni-after-quorum', 2700)")
    wait_for('22 exact orders reach both nodes', cluster.compare)

    print('[8/8] Recreate containers with retained PostgreSQL and DCS data', flush=True)
    cluster.compose('down')
    subprocess.run(['bash', str(ROOT / 'scripts/patroni.sh'), 'up'], cwd=ROOT, env=cluster.env, check=True)
    wait_for('retained cluster has one primary and one streaming replica', cluster.healthy)
    wait_for('retained databases contain identical rows', cluster.compare)
    assert cluster.sql(cluster.leader(), 'SELECT count(*) FROM orders') == '22'
    current = cluster.leader()
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
            'failover_measurement': 'leader container kill through reachable promoted primary; includes replica network reconnection',
            'final_order_count': 22}


def main():
    directory = tempfile.mkdtemp(prefix='pgdr-patroni-')
    cluster = Cluster(directory)
    try:
        report = exercise(cluster)
        output = ROOT / '.local/reports' / f'{cluster.project}-patroni.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
        journal = output.with_suffix('.jsonl')
        journal.write_bytes((cluster.directory / 'acknowledgments.jsonl').read_bytes())
        print(f'PASS: automatic failover, 25 acknowledged / 20 recovered / 5 lost; report: {output}', flush=True)
    except BaseException:
        print(cluster.compose('logs', '--no-color', '--tail=50', check=False).stdout, flush=True)
        raise
    finally:
        cleanup = cluster.compose('down', '--volumes', '--remove-orphans', check=False)
        if cleanup.returncode:
            raise RuntimeError(f'Cleanup failed for {cluster.project}; private files retained at {directory}')
        shutil.rmtree(directory)


if __name__ == '__main__':
    main()
