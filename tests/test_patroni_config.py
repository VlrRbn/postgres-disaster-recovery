"""Check Patroni identity boundaries and private certificate setup."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.patroni_config import configuration


ROOT = Path(__file__).resolve().parents[1]


class PatroniConfigurationTests(unittest.TestCase):
    def test_unknown_member_cannot_generate_connection_settings(self):
        with self.assertRaises(ValueError):
            configuration('pg1 other-host', 'private', 'private', 'private')

    def test_recovery_requires_verified_tls_and_preserves_failed_targets(self):
        config = configuration('pg2', 'super-secret', 'replica-secret', 'api-secret')
        self.assertEqual(config['postgresql']['authentication']['replication']['sslmode'], 'verify-full')
        self.assertFalse(config['postgresql']['remove_data_directory_on_rewind_failure'])
        self.assertFalse(config['postgresql']['remove_data_directory_on_diverged_timelines'])
        self.assertFalse(config['bootstrap']['dcs']['failsafe_mode'])
        self.assertNotIn('host all all all trust', config['postgresql']['pg_hba'])
        self.assertIn('host all all all reject', config['postgresql']['pg_hba'])

    def test_setup_preserves_private_credentials_and_all_tls_identities(self):
        with tempfile.TemporaryDirectory(prefix='pgdr patroni ') as directory:
            env = dict(os.environ, PGDR_PATRONI_DIR=directory)
            command = ['bash', str(ROOT / 'scripts/setup.sh'), 'patroni']
            subprocess.run(command, env=env, check=True, capture_output=True, text=True, timeout=30)
            files = [p for p in Path(directory).rglob('*') if p.is_file()]
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            for path in files:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            for node in ('pg1', 'pg2', 'etcd1', 'etcd2', 'etcd3', 'patroni'):
                subprocess.run(['openssl', 'verify', '-purpose', 'sslclient', '-CAfile',
                                f'{directory}/tls/ca.crt', f'{directory}/tls/{node}.crt'],
                               check=True, capture_output=True, timeout=5)
            subprocess.run(command, env=env, check=True, capture_output=True, timeout=30)
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
            (Path(directory) / 'tls/etcd2.key').unlink()
            result = subprocess.run(command, env=env, capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(directory) / 'tls/etcd2.key').exists())
