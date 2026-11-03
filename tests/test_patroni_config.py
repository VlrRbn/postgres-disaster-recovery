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
    def prepare(self, directory):
        return subprocess.run(['bash', str(ROOT / 'scripts/setup.sh'), 'patroni'],
                              env=dict(os.environ, PGDR_PATRONI_DIR=str(directory)),
                              capture_output=True, text=True, timeout=30)

    def legacy_certificates(self, directory):
        """Recreate the node certificates generated before the shared endpoint."""
        tls = Path(directory) / 'tls'
        extensions = Path(directory) / 'extensions'
        for node in ('pg1', 'pg2'):
            csr = Path(directory) / f'{node}.csr'
            subprocess.run(['openssl', 'req', '-new', '-key', str(tls / f'{node}.key'),
                            '-subj', f'/CN={node}', '-out', str(csr)], check=True, capture_output=True)
            extensions.write_text('basicConstraints=critical,CA:FALSE\n'
                                  'keyUsage=critical,digitalSignature,keyEncipherment\n'
                                  'extendedKeyUsage=serverAuth,clientAuth\n'
                                  f'subjectAltName=DNS:{node},DNS:localhost,IP:127.0.0.1\n')
            subprocess.run(['openssl', 'x509', '-req', '-sha256', '-days', '90', '-in', str(csr),
                            '-CA', str(tls / 'ca.crt'), '-CAkey', str(tls / 'ca.key'),
                            '-set_serial', '10' if node == 'pg1' else '11', '-extfile', str(extensions),
                            '-out', str(tls / f'{node}.crt')], check=True, capture_output=True)
            csr.unlink()
        extensions.unlink()

    def test_legacy_endpoint_upgrade_preserves_ca_keys_and_other_certificates(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.prepare(directory).returncode, 0)
            self.legacy_certificates(directory)
            tls = Path(directory) / 'tls'
            before = {p: p.read_bytes() for p in tls.iterdir()}
            self.assertEqual(self.prepare(directory).returncode, 0)
            for path, original in before.items():
                if path.name in ('pg1.crt', 'pg2.crt'):
                    self.assertNotEqual(original, path.read_bytes())
                    for identity in (path.stem, 'haproxy', 'localhost'):
                        subprocess.run(['openssl', 'verify', '-verify_hostname', identity,
                                        '-CAfile', str(tls / 'ca.crt'), str(path)],
                                       check=True, capture_output=True, timeout=5)
                else:
                    self.assertEqual(original, path.read_bytes(), path)
            upgraded = {p: p.read_bytes() for p in tls.iterdir()}
            self.assertEqual(self.prepare(directory).returncode, 0)
            self.assertEqual(upgraded, {p: p.read_bytes() for p in tls.iterdir()})

    def test_failed_upgrade_preserves_both_previous_certificates(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.prepare(directory).returncode, 0)
            self.legacy_certificates(directory)
            tls = Path(directory) / 'tls'
            before = {p: p.read_bytes() for p in tls.iterdir()}
            binary = Path(directory) / 'bin'
            binary.mkdir()
            real_openssl = subprocess.check_output(['which', 'openssl'], text=True).strip()
            wrapper = binary / 'openssl'
            wrapper.write_text('#!/bin/bash\n'
                               'if [[ "$1" == x509 && "$2" == -req && "$*" == *pg2.csr* ]]; then exit 1; fi\n'
                               f'exec "{real_openssl}" "$@"\n')
            wrapper.chmod(0o700)
            result = subprocess.run(['bash', str(ROOT / 'scripts/setup.sh'), 'patroni'],
                                    env=dict(os.environ, PGDR_PATRONI_DIR=directory,
                                             PATH=f'{binary}:{os.environ["PATH"]}'),
                                    capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(before, {p: p.read_bytes() for p in tls.iterdir()})

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
