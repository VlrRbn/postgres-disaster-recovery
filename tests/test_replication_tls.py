"""Validate generated replication identities without touching Docker or user secrets."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReplicationTLSSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.material = Path(cls.fixture.name)
        result = subprocess.run(['bash', str(ROOT / 'scripts/setup.sh'), 'replication-tls'],
                                env=dict(os.environ, PGDR_REPLICATION_DIR=str(cls.material)),
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise AssertionError(result.stderr)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='pgdr tls ')
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)
        shutil.copytree(self.material / 'tls', self.directory / 'tls')

    def run_setup(self, directory=None, **overrides):
        env = dict(os.environ, PGDR_REPLICATION_DIR=str(directory or self.directory))
        env.update(overrides)
        return subprocess.run(['bash', str(ROOT / 'scripts/setup.sh'), 'replication-tls'],
                              env=env, capture_output=True, text=True, timeout=20)

    def hashes(self):
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (self.directory / 'tls').iterdir()}

    def test_fresh_setup_creates_private_complete_material(self):
        fresh = self.directory / 'new runtime'
        result = self.run_setup(fresh)
        self.assertEqual(result.returncode, 0, result.stderr)
        tls = fresh / 'tls'
        self.assertEqual({p.name for p in tls.iterdir()},
                         {f'{name}.{suffix}' for name in ('ca', 'primary', 'standby')
                          for suffix in ('crt', 'key')})
        self.assertEqual(tls.stat().st_mode & 0o777, 0o700)
        for name in ('ca', 'primary', 'standby'):
            self.assertEqual((tls / f'{name}.key').stat().st_mode & 0o777, 0o600)

    def test_repeated_setup_preserves_keys_and_certificates(self):
        before = self.hashes()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('preserved', result.stdout)
        self.assertEqual(self.hashes(), before)

    def test_incomplete_directory_is_not_silently_replaced(self):
        (self.directory / 'tls/standby.key').unlink()
        before = self.hashes()
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Incomplete', result.stderr)
        self.assertEqual(self.hashes(), before)

    def test_mismatched_key_is_rejected_without_rewriting_material(self):
        shutil.copyfile(self.directory / 'tls/standby.key', self.directory / 'tls/primary.key')
        before = self.hashes()
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)
        self.assertEqual(self.hashes(), before)

    def test_trusted_certificate_with_wrong_hostname_is_rejected(self):
        for suffix in ('crt', 'key'):
            shutil.copyfile(self.directory / f'tls/standby.{suffix}',
                            self.directory / f'tls/primary.{suffix}')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('hostname mismatch', result.stderr)

    def test_exposed_private_key_is_rejected(self):
        (self.directory / 'tls/primary.key').chmod(0o644)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('group/world-readable', result.stderr)

    def test_failed_generation_cleans_temporary_private_material(self):
        fake_bin = self.directory / 'bin'
        fake_bin.mkdir()
        openssl = fake_bin / 'openssl'
        openssl.write_text('#!/usr/bin/env bash\nexit 1\n')
        openssl.chmod(0o755)
        fresh = self.directory / 'failed'
        result = self.run_setup(fresh, PATH=f'{fake_bin}:{os.environ["PATH"]}')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(fresh.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
