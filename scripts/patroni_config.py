"""Prepare private Patroni configuration and check its verified HTTPS API."""

import json
import os
from pathlib import Path
import ssl
import sys
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


TLS = '/var/lib/postgresql/patroni/tls'
CONFIG = Path('/var/lib/postgresql/patroni/patroni.json')


def configuration(node: str, superuser: str, replication: str, api: str) -> dict:
    if node not in ('pg1', 'pg2'):
        raise ValueError('Patroni node must be pg1 or pg2')
    return {
        'scope': 'orders-patroni', 'namespace': '/postgres-dr/', 'name': node,
        'restapi': {
            'listen': '0.0.0.0:8008', 'connect_address': f'{node}:8008',
            'certfile': f'{TLS}/server.crt', 'keyfile': f'{TLS}/server.key',
            'cafile': f'{TLS}/ca.crt',
            'authentication': {'username': 'patroni_admin', 'password': api},
        },
        'ctl': {'insecure': False, 'cacert': f'{TLS}/ca.crt'},
        'etcd3': {
            'hosts': 'etcd1:2379,etcd2:2379,etcd3:2379', 'protocol': 'https',
            'cacert': f'{TLS}/ca.crt', 'cert': f'{TLS}/etcd-client.crt',
            'key': f'{TLS}/etcd-client.key',
        },
        'bootstrap': {
            'dcs': {
                'ttl': 20, 'loop_wait': 5, 'retry_timeout': 5,
                'maximum_lag_on_failover': 1048576, 'check_timeline': True,
                'synchronous_mode': False, 'failsafe_mode': False,
                'postgresql': {
                    'use_pg_rewind': True, 'use_slots': True,
                    'parameters': {
                        'wal_level': 'replica', 'hot_standby': 'on',
                        'max_wal_senders': 4, 'max_replication_slots': 4,
                        'max_slot_wal_keep_size': '256MB', 'wal_keep_size': '64MB',
                        'shared_buffers': '64MB', 'max_connections': 50,
                        'password_encryption': 'scram-sha-256',
                        'ssl': 'on', 'ssl_min_protocol_version': 'TLSv1.2',
                        'ssl_cert_file': f'{TLS}/server.crt',
                        'ssl_key_file': f'{TLS}/server.key',
                        'ssl_ca_file': f'{TLS}/ca.crt', 'archive_mode': 'off',
                    },
                },
            },
            'initdb': [{'encoding': 'UTF8'}, 'data-checksums'],
            'post_bootstrap': '/bin/bash /opt/patroni.sh init',
        },
        'postgresql': {
            'listen': '0.0.0.0:5432', 'connect_address': f'{node}:5432',
            'data_dir': '/var/lib/postgresql/data/pgdata',
            'basebackup': {'checkpoint': 'fast'},
            'pgpass': '/var/lib/postgresql/patroni/pgpass',
            'authentication': {
                'superuser': {
                    'username': 'postgres', 'password': superuser,
                    'sslmode': 'verify-full', 'sslrootcert': f'{TLS}/ca.crt',
                },
                'replication': {
                    'username': 'replicator', 'password': replication,
                    'sslmode': 'verify-full', 'sslrootcert': f'{TLS}/ca.crt',
                },
            },
            'pg_hba': [
                'local all all trust',
                'hostssl replication replicator samenet scram-sha-256',
                'hostssl all postgres samenet scram-sha-256',
                'host all all all reject',
            ],
            'remove_data_directory_on_rewind_failure': False,
            'remove_data_directory_on_diverged_timelines': False,
        },
        'watchdog': {'mode': 'off'},
    }


def probe(endpoint: str) -> int:
    if endpoint not in ('primary', 'replica', 'health'):
        raise ValueError('Unknown health endpoint')
    context = ssl.create_default_context(cafile=f'{TLS}/ca.crt')
    try:
        with urlopen(f'https://localhost:8008/{endpoint}', context=context, timeout=3):
            return 0
    except HTTPError as error:
        if error.code == 503:
            return 1
        raise


def main() -> int:
    if sys.argv[1:] == ['write']:
        credentials = [Path(f'/run/secrets/{name}_password').read_text().strip()
                       for name in ('postgres', 'replication', 'patroni_api')]
        if not all(credentials):
            raise ValueError('Empty Patroni credential file')
        config = configuration(os.environ['PGDR_PATRONI_NODE'], *credentials)
        with os.fdopen(os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as out:
            json.dump(config, out, indent=2)
            out.write('\n')
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == 'probe':
        return probe(sys.argv[2])
    raise ValueError('Usage: patroni_config.py write | probe {primary|replica|health}')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, URLError):
        print('Patroni configuration or verified API check failed; inspect private files and node logs.', file=sys.stderr)
        sys.exit(2)
