"""Verify alert state transitions, job results, and real local TLS transports."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import base64
from copy import deepcopy
from email import message_from_bytes
import fcntl
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import smtplib
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from typing import cast

from scripts import backup_alerts as alerts


class AlertStateTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.config = self.root / 'config.json'
        self.state = self.root / 'state'
        self.settings = deepcopy(alerts.TEMPLATE)
        self.settings['telegram'].update(enabled=True, bot_token='123:test_token', chat_id='456')
        self.settings['email'].update(enabled=True, host='smtp.example.test',
                                      **{'from': 'backup@example.test', 'to': 'ops@example.test'})
        self.write_config()
        self.telegram = self.enterContext(patch.object(alerts, 'send_telegram'))
        self.email = self.enterContext(patch.object(alerts, 'send_email'))
        self.log = io.StringIO()
        self.enterContext(redirect_stderr(self.log))
        self.enterContext(patch.dict(os.environ, {
            'PGDR_ALERT_CONFIG': str(self.config), 'PGDR_ALERT_STATE_DIR': str(self.state),
            'PGDR_PROJECT': 'postgres-dr-alert-test',
        }))

    def write_config(self):
        self.config.write_text(json.dumps(self.settings))
        self.config.chmod(0o600)

    def event(self, result, job='backup-health', project='postgres-dr-alert-test'):
        return alerts.deliver_alerts(self.config, self.state, project, job, result)

    def test_initial_success_is_silent_and_failure_recovery_are_sent_once(self):
        for result in (0, 1, 1, 0, 0):
            self.assertEqual(self.event(result), 0)
        for sender in (self.telegram, self.email):
            self.assertEqual(sender.call_count, 2)
            self.assertIn('FAILED', sender.call_args_list[0].args[1])
            self.assertIn('RECOVERED', sender.call_args_list[1].args[1])
        self.event(1)
        self.assertEqual(self.telegram.call_count, 3)

    def test_partial_delivery_retries_only_failed_channel(self):
        self.telegram.side_effect = OSError('123:test_token sensitive remote error')
        self.assertEqual(self.event(1), 1)
        self.assertEqual(self.email.call_count, 1)
        self.telegram.side_effect = None
        self.assertEqual(self.event(1), 0)
        self.assertEqual(self.telegram.call_count, 2)
        self.assertEqual(self.email.call_count, 1)
        self.assertNotIn('123:test_token', self.log.getvalue())
        self.assertNotIn('sensitive remote error', self.log.getvalue())

    def test_failed_recovery_delivery_is_retried_without_duplicate_success(self):
        self.event(1)
        self.email.side_effect = smtplib.SMTPException('private SMTP response')
        self.assertEqual(self.event(0), 1)
        self.email.side_effect = None
        self.assertEqual(self.event(0), 0)
        self.assertEqual(self.telegram.call_count, 2)
        self.assertEqual(self.email.call_count, 3)

    def test_no_recovery_is_sent_to_channel_that_never_received_failure(self):
        self.telegram.side_effect = OSError('unavailable')
        self.event(1)
        self.telegram.side_effect = None
        self.event(0)
        self.assertEqual(self.telegram.call_count, 1)
        self.assertEqual(self.email.call_count, 2)

    def test_jobs_and_projects_have_separate_incidents(self):
        self.event(1, job='backup')
        self.event(0, job='backup-health')
        self.event(1, project='postgres-dr-other')
        self.assertEqual(self.email.call_count, 2)
        self.assertTrue(all('FAILED' in call.args[1] for call in self.email.call_args_list))

    def test_recipient_change_does_not_inherit_delivered_state(self):
        self.event(1)
        self.settings['telegram']['chat_id'] = '789'
        self.write_config()
        self.event(1)
        self.assertEqual(self.telegram.call_count, 2)
        self.assertEqual(self.email.call_count, 1)

    def test_invalid_channel_does_not_block_other_channel(self):
        for name, field in (('telegram', 'bot_token'), ('email', 'from')):
            with self.subTest(channel=name):
                saved = self.settings[name].pop(field)
                self.write_config()
                self.assertEqual(self.event(1), 1)
                self.settings[name][field] = saved
                self.write_config()
        self.assertEqual(self.email.call_count, 1)
        self.assertEqual(self.telegram.call_count, 1)

    def test_missing_or_disabled_config_creates_no_state_and_sends_nothing(self):
        self.config.unlink()
        self.assertEqual(self.event(1), 0)
        self.settings = deepcopy(alerts.TEMPLATE)
        self.write_config()
        self.assertEqual(self.event(1), 0)
        self.assertFalse(self.state.exists())
        self.telegram.assert_not_called()
        self.email.assert_not_called()

    def test_malformed_email_addresses_do_not_abort_telegram(self):
        for index, address in enumerate(('bad@', '@example.test', 'bad@@example.test')):
            with self.subTest(address=address):
                self.settings['email']['to'] = address
                self.write_config()
                self.assertEqual(self.event(1, project=f'postgres-dr-bad-address-{index}'), 1)
        self.assertEqual(self.telegram.call_count, 3)
        self.email.assert_not_called()

    def test_state_is_private_and_never_contains_credentials(self):
        self.event(1)
        state = self.state / 'postgres-dr-alert-test-backup-health.json'
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertNotIn('123:test_token', state.read_text())

    def test_corrupt_state_and_busy_lock_are_reported_without_sending(self):
        self.event(1)
        self.telegram.reset_mock()
        self.email.reset_mock()
        lock_path = self.state / 'postgres-dr-alert-test-backup-health.lock'
        with lock_path.open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.event(0)
        state_path = lock_path.with_suffix('.json')
        state_path.write_text('{broken')
        with self.assertRaises(ValueError):
            self.event(0)
        self.telegram.assert_not_called()
        self.email.assert_not_called()

    def test_setup_preserves_private_config_and_rejects_exposed_credentials(self):
        before = self.config.read_text()
        with redirect_stdout(io.StringIO()):
            alerts.setup_config(self.config)
        self.assertEqual(self.config.read_text(), before)
        self.config.chmod(0o644)
        with self.assertRaises(ValueError):
            self.event(1)
        self.telegram.assert_not_called()

    def test_setup_creates_disabled_private_config(self):
        self.config.unlink()
        with redirect_stdout(io.StringIO()):
            alerts.setup_config(self.config)
        self.assertEqual(json.loads(self.config.read_text()), alerts.TEMPLATE)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.telegram.assert_not_called()
        self.email.assert_not_called()

    def test_job_exit_is_preserved_and_notification_failure_is_visible(self):
        self.telegram.side_effect = OSError('unavailable')
        command = [sys.executable, '-c', 'raise SystemExit(75)']
        self.assertEqual(alerts.run_job('backup-health', command), 75)
        self.assertEqual(alerts.run_job('backup-health', [sys.executable, '-c', 'pass']), 0)
        self.telegram.side_effect = None
        self.event(1)
        self.telegram.side_effect = OSError('unavailable')
        self.assertEqual(alerts.run_job('backup-health', [sys.executable, '-c', 'pass']), 1)

    def test_cli_keeps_health_json_stdout_and_propagates_exit_status(self):
        self.config.unlink()
        command = [sys.executable, str(alerts.ROOT / 'scripts/backup_alerts.py'),
                   'run', 'backup-health', '--', sys.executable, '-c',
                   'print(\'{"status": "unhealthy"}\'); raise SystemExit(1)']
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), {'status': 'unhealthy'})

    def test_shell_scheduled_entrypoint_preserves_json_and_command_failure(self):
        self.config.unlink()
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        make = bin_dir / 'make'
        make.write_text('#!/usr/bin/env python3\nprint(\'{"status": "unhealthy"}\')\nraise SystemExit(1)\n')
        make.chmod(0o755)
        project = 'postgres-dr-alert-wrapper-' + self.root.name.replace('_', '-').lower()
        lock = alerts.ROOT / f'.local/locks/schedule-{project}.lock'
        self.addCleanup(lock.unlink, missing_ok=True)
        env = dict(os.environ, PGDR_PROJECT=project, PGDR_REPOSITORY='local',
                   PGDR_S3_FIXTURE='0', PATH=f'{bin_dir}:{os.environ["PATH"]}')
        result = subprocess.run(['bash', str(alerts.ROOT / 'scripts/backup.sh'), 'scheduled-health'],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'status': 'unhealthy'})
        self.assertIn('Scheduled backup-health failed', result.stderr)


class SMTPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        server = cast('SMTPServer', self.server)
        self.wfile.write(b'220 localhost test SMTP\r\n')
        while line := self.rfile.readline():
            verb = line.split(None, 1)[0].upper()
            if verb == b'EHLO':
                self.wfile.write(b'250-localhost\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n')
            elif verb == b'AUTH':
                credentials = base64.b64decode(line.split()[2])
                server.auths.append((isinstance(self.connection, ssl.SSLSocket), credentials))
                self.wfile.write(b'235 Authenticated\r\n')
            elif verb == b'STARTTLS':
                self.wfile.write(b'220 Begin TLS\r\n')
                self.rfile.close()
                self.wfile.close()
                try:
                    self.connection = server.context.wrap_socket(self.connection, server_side=True)
                except ssl.SSLError:
                    return
                self.rfile = self.connection.makefile('rb')
                self.wfile = self.connection.makefile('wb', buffering=0)
            elif verb in (b'MAIL', b'RCPT', b'RSET'):
                self.wfile.write(b'250 OK\r\n')
            elif verb == b'DATA':
                self.wfile.write(b'354 End with dot\r\n')
                lines = []
                while (part := self.rfile.readline()) not in (b'.\r\n', b''):
                    lines.append(part[1:] if part.startswith(b'..') else part)
                if server.refuse:
                    self.wfile.write(b'451 Temporary test delivery failure\r\n')
                else:
                    server.messages.append(message_from_bytes(b''.join(lines)))
                    self.wfile.write(b'250 Accepted\r\n')
            elif verb == b'QUIT':
                self.wfile.write(b'221 Bye\r\n')
                return
            else:
                self.wfile.write(b'500 Unsupported test command\r\n')

    def finish(self):
        try:
            super().finish()
        finally:
            if isinstance(self.connection, ssl.SSLSocket):
                self.connection.close()


class TelegramHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        server = cast('TelegramServer', self.server)
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        server.requests.append((self.path, payload))
        body = json.dumps(server.reply).encode()
        self.send_response(server.status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass  # Test bot tokens must not be written to HTTP access logs.


class SMTPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, context):
        self.context = context
        self.messages = []
        self.auths = []
        self.refuse = False
        super().__init__(('127.0.0.1', 0), SMTPHandler)


class TelegramServer(ThreadingHTTPServer):
    def __init__(self):
        self.requests = []
        self.reply = {'ok': True, 'result': {'message_id': 1}}
        self.status = 200
        super().__init__(('127.0.0.1', 0), TelegramHandler)


class AlertTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.work.cleanup)
        cls.path = Path(cls.work.name)
        cert, key = cls.path / 'cert.pem', cls.path / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                        '-keyout', str(key), '-out', str(cert)],
                       check=True, capture_output=True, timeout=15)
        cls.client_context = ssl.create_default_context(cafile=str(cert))
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(cert, key)
        cls.smtp = SMTPServer(server_context)
        cls.smtps = SMTPServer(server_context)
        cls.smtps.socket = server_context.wrap_socket(cls.smtps.socket, server_side=True)
        cls.telegram = TelegramServer()
        cls.telegram.socket = server_context.wrap_socket(cls.telegram.socket, server_side=True)
        for server in (cls.smtp, cls.smtps, cls.telegram):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            cls.addClassCleanup(server.server_close)
            cls.addClassCleanup(server.shutdown)
        cls.real_connection = http.client.HTTPSConnection

    def setUp(self):
        self.smtp.messages.clear()
        self.smtp.refuse = False
        self.smtps.messages.clear()
        self.smtp.auths.clear()
        self.smtps.auths.clear()
        self.telegram.requests.clear()
        self.telegram.status = 200
        self.telegram.reply = {'ok': True, 'result': {'message_id': 1}}
        self.email_settings = {'host': 'localhost', 'port': self.smtp.server_address[1],
                               'security': 'starttls', 'from': 'backup@example.test',
                               'to': 'ops@example.test', 'username': '', 'password': '',
                               'enabled': True}
        self.telegram_settings = {'bot_token': '123:test_token', 'chat_id': '456', 'enabled': True}
        self.stack = self.enterContext(ExitStack())
        self.stack.enter_context(patch.object(alerts.ssl, 'create_default_context',
                                              return_value=self.client_context))
        self.stack.enter_context(patch.object(alerts, 'HTTPSConnection',
                                              side_effect=self.local_telegram_connection))

    def local_telegram_connection(self, host, **kwargs):
        self.assertEqual(host, 'api.telegram.org')
        return self.real_connection('localhost', self.telegram.server_address[1], **kwargs)

    def test_both_transports_accept_real_tls_requests(self):
        alerts.send_telegram(self.telegram_settings, 'FAILED: backup-health', 2)
        alerts.send_email(self.email_settings, 'FAILED: backup-health\nDetails', 2)
        self.assertEqual(self.telegram.requests, [('/bot123:test_token/sendMessage',
                          {'chat_id': '456', 'text': 'FAILED: backup-health'})])
        self.assertEqual(self.smtp.messages[0]['To'], 'ops@example.test')
        self.assertIn('Details', self.smtp.messages[0].get_payload())

    def test_http_and_api_errors_are_not_accepted_as_delivery(self):
        for status, body in ((500, {'ok': False}), (200, {'ok': False}),
                             (200, {'ok': True}), (200, {'ok': True, 'result': {}})):
            with self.subTest(status=status, body=body):
                self.telegram.status, self.telegram.reply = status, body
                with self.assertRaises(ValueError):
                    alerts.send_telegram(self.telegram_settings, 'FAILED', 2)

    def test_smtp_implicit_tls_is_supported(self):
        self.email_settings.update(security='ssl', port=self.smtps.server_address[1])
        alerts.send_email(self.email_settings, 'FAILED: backup', 2)
        self.assertEqual(len(self.smtps.messages), 1)

    def test_smtp_authentication_uses_tls_for_both_modes(self):
        for security, server in (('starttls', self.smtp), ('ssl', self.smtps)):
            with self.subTest(security=security):
                self.email_settings.update(security=security, port=server.server_address[1],
                                           username='test-user', password='test-password')
                alerts.send_email(self.email_settings, 'FAILED: backup', 2)
                self.assertEqual(server.auths, [(True, b'\x00test-user\x00test-password')])

    def test_untrusted_certificates_are_rejected_for_both_channels(self):
        untrusted = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        with patch.object(alerts.ssl, 'create_default_context', return_value=untrusted):
            with self.assertRaises(ssl.SSLCertVerificationError):
                alerts.send_telegram(self.telegram_settings, 'FAILED', 2)
            with self.assertRaises(ssl.SSLCertVerificationError):
                alerts.send_email(self.email_settings, 'FAILED', 2)
        self.assertFalse(self.telegram.requests)
        self.assertFalse(self.smtp.messages)

    def test_real_channel_failure_retry_dedup_and_recovery(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            config = root / 'config.json'
            config.write_text(json.dumps({'telegram': self.telegram_settings, 'email': self.email_settings}))
            config.chmod(0o600)
            with patch.dict(os.environ, {'PGDR_ALERT_CONFIG': str(config),
                            'PGDR_ALERT_STATE_DIR': str(root / 'state'),
                            'PGDR_PROJECT': 'postgres-dr-alert-fixture'}), redirect_stderr(io.StringIO()):
                failure = [sys.executable, '-c', 'raise SystemExit(1)']
                success = [sys.executable, '-c', 'pass']
                self.smtp.refuse = True
                self.assertEqual(alerts.run_job('backup-health', failure), 1)
                self.assertEqual(len(self.telegram.requests), 1)
                self.assertEqual(len(self.smtp.messages), 0)
                self.smtp.refuse = False
                self.assertEqual(alerts.run_job('backup-health', failure), 1)
                self.assertEqual(len(self.telegram.requests), 1)
                self.assertEqual(len(self.smtp.messages), 1)
                self.assertEqual(alerts.run_job('backup-health', success), 0)
                self.assertEqual(alerts.run_job('backup-health', success), 0)
                self.assertEqual(len(self.telegram.requests), 2)
                self.assertEqual(len(self.smtp.messages), 2)


if __name__ == '__main__':
    unittest.main()
