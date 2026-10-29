"""Check user-unit installation without touching the real user's manager."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
UNITS = (
    'postgres-dr-backup.service', 'postgres-dr-backup.timer',
    'postgres-dr-backup-health.service', 'postgres-dr-backup-health.timer',
)


class ScheduleSetupTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name)
        self.config_home = self.path / 'config'
        self.config = self.config_home / 'postgres-dr/schedule.env'
        self.unit_dir = self.config_home / 'systemd/user'
        self.calls = self.path / 'systemctl-calls.jsonl'
        fake_bin = self.path / 'bin'
        fake_bin.mkdir()
        # Only daemon-reload and state inspection are allowed; enabling a timer fails.
        systemctl = fake_bin / 'systemctl'
        systemctl.write_text('''#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ['SYSTEMCTL_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--user', 'daemon-reload']:
    sys.exit(0)
if sys.argv[1:3] == ['--user', 'show']:
    if os.environ.get('FAKE_STATE_ERROR'):
        sys.exit(1)
    print(os.environ.get('FAKE_UNIT_STATE', 'inactive'))
    sys.exit(0)
sys.exit('Unexpected systemctl operation during installation/removal')
''')
        systemctl.chmod(0o755)
        runtime = self.path / 'run'
        runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.config_home),
                        XDG_RUNTIME_DIR=str(runtime), SYSTEMCTL_CALLS=str(self.calls),
                        PATH=f'{fake_bin}:{os.environ["PATH"]}')

    def run_setup(self, command='schedule', *, script=None):
        return subprocess.run(['bash', str(script or ROOT / 'scripts/setup.sh'), command],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def install(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_is_private_and_does_not_enable_timers(self):
        self.install()
        settings = {key: json.loads(value) for key, value in
                    (line.split('=', 1) for line in self.config.read_text().splitlines())}
        self.assertEqual(settings['PGDR_ROOT'], str(ROOT))
        self.assertEqual(settings['PGDR_PROJECT'], 'postgres-dr-local')
        self.assertEqual(settings['PGDR_REPOSITORY'], 'local')
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertTrue(all((self.unit_dir / unit).is_file() for unit in UNITS))
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()],
                         [['--user', 'daemon-reload']])

    def test_reinstall_preserves_operator_configuration_and_refreshes_units(self):
        self.install()
        custom = 'PGDR_ROOT="/custom/checkout"\nPGDR_PROJECT="postgres-dr-custom"\n'
        self.config.write_text(custom)
        health_unit = self.unit_dir / 'postgres-dr-backup-health.service'
        health_unit.write_text('[Service]\nExecStart=/usr/bin/make scheduled-health\n')
        self.install()
        self.assertEqual(self.config.read_text(), custom)
        self.assertIn(' scheduled-backup-health\n', health_unit.read_text())

    def test_remove_refuses_an_active_job(self):
        self.install()
        self.env['FAKE_UNIT_STATE'] = 'activating'
        result = self.run_setup('schedule-remove')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('still running', result.stderr)
        self.assertTrue(all((self.unit_dir / unit).is_file() for unit in UNITS))

    def test_remove_retains_configuration(self):
        self.install()
        content = self.config.read_text()
        result = self.run_setup('schedule-remove')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any((self.unit_dir / unit).exists() for unit in UNITS))
        self.assertEqual(self.config.read_text(), content)

    def test_remove_refuses_when_manager_state_is_unavailable(self):
        self.install()
        self.env['FAKE_STATE_ERROR'] = '1'
        result = self.run_setup('schedule-remove')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('operation refused', result.stderr)
        self.assertTrue(all((self.unit_dir / unit).is_file() for unit in UNITS))

    def test_checkout_path_preserves_spaces_quotes_and_dollar_signs(self):
        checkout = self.path / 'checkout with % and $ and "quotes"'
        (checkout / 'scripts').mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/setup.sh', checkout / 'scripts/setup.sh')
        (checkout / 'systemd').symlink_to(ROOT / 'systemd', target_is_directory=True)
        result = self.run_setup(script=checkout / 'scripts/setup.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(line for line in self.config.read_text().splitlines()
                    if line.startswith('PGDR_ROOT='))
        self.assertEqual(json.loads(line.split('=', 1)[1]), str(checkout))


if __name__ == '__main__':
    unittest.main()
