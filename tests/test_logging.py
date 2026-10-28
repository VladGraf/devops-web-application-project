"""Offline logging checks. Deployment bodies and Ansible are local test stubs."""
import json
import os
import pty
import select
import time
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LoggingChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='final-project-logging-test-')
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / 'project with spaces'
        (self.project / 'scripts').mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/redact.awk', self.project / 'scripts/redact.awk')
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(('FINAL_PROJECT_', 'ANSIBLE_')):
                self.env.pop(key, None)

    def redact(self, text, **secrets):
        result = subprocess.run(['awk', '-f', str(ROOT / 'scripts/redact.awk')],
                                input=text, text=True, capture_output=True,
                                env=dict(self.env, **secrets), check=True)
        return result.stdout

    def run_log(self, body, expected_code=0, input_text=None, **secrets):
        (self.project / 'scripts/deploy-project.sh').write_text(body)
        result = subprocess.run(['/bin/bash', '-c',
                                 'set -euo pipefail; source "$1/scripts/logging.sh"; run_deployment_logged "$2" 0',
                                 'test', str(ROOT), str(self.project)],
                                input=input_text, text=True, capture_output=True,
                                env=dict(self.env, **secrets))
        self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
        return result

    def logs(self):
        return sorted((self.project / '.state/logs').glob('*.log'))

    def test_failed_output_and_exit_code_are_saved(self):
        result = self.run_log('printf "stdout-marker\\n"; printf "stderr-marker\\n" >&2; exit 37\n', 37)
        log = self.logs()[0]
        text = log.read_text()
        self.assertIn('stdout-marker', text)
        self.assertIn('stderr-marker', text)
        self.assertIn('Deployment exit_code=37', text)
        self.assertIn(str(log), result.stderr)
        self.assertIn('failed (exit_code=37)', result.stderr)

    def test_attempts_are_unique_private_and_previous_logs_are_kept(self):
        self.run_log('echo first-attempt\n')
        first = self.logs()[0]
        original = first.read_text()
        self.run_log('echo second-attempt\n')
        self.assertEqual(len(self.logs()), 2)
        self.assertEqual(first.read_text(), original)
        self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(first.parent.stat().st_mode), 0o700)

    def test_secrets_are_hidden_in_saved_and_terminal_output(self):
        body = '''echo 'password="super secret password" token=abc-123'
echo 'https://someone:login-secret@example.org/?api_key=query-secret&ok=1'
echo 'unlabeled private-env-value' >&2
exit 3
'''
        result = self.run_log(body, 3, FINAL_PROJECT_TEST_TOKEN='private-env-value')
        text = self.logs()[0].read_text() + result.stdout + result.stderr
        for secret in ('super secret password', 'abc-123', 'login-secret', 'query-secret', 'private-env-value'):
            self.assertNotIn(secret, text)
        self.assertIn('[REDACTED]', text)
        self.assertIn('example.org', text)

    def test_escaped_ansible_json_secrets_are_hidden_but_errors_remain(self):
        payload = json.dumps({'stdout': json.dumps({'token': 'nested-secret', 'password': 'a b " c'}),
                              'stderr': 'exact validation failure', 'rc': 17})
        output = self.redact(payload)
        self.assertNotIn('nested-secret', output)
        self.assertNotIn('a b', output)
        self.assertIn('exact validation failure', output)
        self.assertIn('"rc": 17', output)

    def test_cli_arrays_headers_and_url_secrets(self):
        output = self.redact('''cmd: ["k3d", "--token", "array-secret", "--wait"]
Authorization: Bearer bearer-secret
{"Authorization":"Basic basic-secret"}
https://user:url-secret@registry.example/path?token=url-query-secret&next=ok
''')
        for secret in ('array-secret', 'bearer-secret', 'basic-secret', 'url-secret', 'url-query-secret'):
            self.assertNotIn(secret, output)
        self.assertIn('--wait', output)
        self.assertIn('next=ok', output)

    def test_multiline_and_private_key_secrets(self):
        output = self.redact('''password: |
  literal-password-one
  literal-password-two
stderr: first error
credentials: {
 "hidden": "nested-private-value"
}
-----BEGIN RSA PRIVATE KEY-----
private-key-content
-----END RSA PRIVATE KEY-----
stderr: final error
''')
        for secret in ('literal-password-one', 'literal-password-two', 'nested-private-value', 'private-key-content'):
            self.assertNotIn(secret, output)
        self.assertIn('first error', output)
        self.assertIn('final error', output)

    def test_known_environment_secrets_with_spaces_and_json_escapes(self):
        value = 'complex "password" with \\ escapes'
        payload = json.dumps({'message': value}) + '\npassword=' + value + '\n'
        output = self.redact(payload, FINAL_PROJECT_TEST_PASSWORD=value)
        self.assertNotIn('complex', output)
        self.assertNotIn('escapes', output)
        self.assertIn('[REDACTED]', output)

    def test_nested_secret_object_does_not_hide_following_errors(self):
        payload = json.dumps({'stdout': json.dumps({'credentials': {'password': 'object-secret'}}),
                              'stderr': 'keep this exact failure', 'rc': 19})
        output = self.redact(payload)
        self.assertNotIn('object-secret', output)
        self.assertIn('keep this exact failure', output)
        self.assertIn('"rc": 19', output)

    def test_weak_environment_secret_does_not_break_field_redaction(self):
        output = self.redact('password=generated-secret --token another-secret\n', FINAL_PROJECT_TEST_PASSWORD='pass')
        self.assertNotIn('generated-secret', output)
        self.assertNotIn('another-secret', output)

    def test_common_tokens_are_hidden_without_hiding_disk_errors(self):
        output = self.redact('disk-full error\nghp_examplePrivateToken\nsk-proj-examplePrivateToken\nBearer standalone-token\n')
        self.assertIn('disk-full error', output)
        self.assertNotIn('examplePrivateToken', output)
        self.assertNotIn('standalone-token', output)

    def test_standard_ansible_error_is_not_lost_to_redaction(self):
        message = 'TASK [Create the K3s cluster]\nfatal: [localhost]: FAILED! => {"rc": 1, "stdout": "", "stderr": "invalid configuration"}\n'
        self.assertEqual(self.redact(message), message)

    def test_input_is_not_consumed_by_the_logger(self):
        result = self.run_log('printf "Approve? [y/N]\\n"; read -r answer; [[ "$answer" == y ]]; echo accepted\n',
                              input_text='y\n')
        self.assertIn('accepted', result.stdout)
        self.assertNotIn('\ny\n', self.logs()[0].read_text())

    def test_redactor_failure_is_reported_as_failure(self):
        (self.project / 'scripts/redact.awk').write_text('BEGIN {exit 9}\n')
        marker = self.project / 'must-not-deploy'
        (self.project / 'scripts/deploy-project.sh').write_text(f'touch "{marker}"; exit 0\n')
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1/scripts/logging.sh"; run_deployment_logged "$2" 0',
                                 'test', str(ROOT), str(self.project)], text=True, capture_output=True, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('redactor=9', result.stderr)
        self.assertFalse(marker.exists())
        self.assertIn(str(self.logs()[0]), result.stderr)

    def test_prompt_and_progress_reach_terminal_and_log_before_exit(self):
        # A real terminal keeps installer_confirm interactive; no host actions run.
        installer = ROOT / 'scripts/installer.sh'
        body = f'''set -e
source "{installer}"
INSTALL_ASSUME_YES=0
printf 'live-progress token=stream-secret\n'
installer_confirm
printf 'test-confirmed\n'
'''
        (self.project / 'scripts/deploy-project.sh').write_text(body)
        master, slave = pty.openpty()
        process = subprocess.Popen(['/bin/bash', '-c',
                                    'set -euo pipefail; source "$1/scripts/logging.sh"; run_deployment_logged "$2" 0',
                                    'test', str(ROOT), str(self.project)],
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=dict(self.env, FINAL_PROJECT_CONFIRM_TIMEOUT_SECONDS='5'))
        os.close(slave)
        received = b''
        try:
            deadline = time.monotonic()+3
            while b'Approve the host actions' not in received and time.monotonic()<deadline:
                if select.select([process.stdout], [], [], 0.1)[0]:
                    chunk = os.read(process.stdout.fileno(), 8192)
                    if not chunk:
                        break
                    received += chunk
            self.assertIn(b'Approve the host actions', received,
                          'Prompt was buffered until EOF: '+received.decode(errors='replace'))
            self.assertIsNone(process.poll(), 'The fixture must still be awaiting input')
            log_text = self.logs()[0].read_text()
            self.assertIn('live-progress', log_text)
            self.assertIn('Approve the host actions', log_text)
            self.assertNotIn('stream-secret', log_text)
            self.assertNotIn(b'stream-secret', received)
            # Explicit test-only consent; installer_apply is never invoked.
            os.write(master, b'y\n')
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, (received+output).decode(errors='replace'))
            self.assertIn(b'test-confirmed', received+output)
        finally:
            os.close(master)  # EOF allows a failed fixture to finish without approval.
            if process.poll() is None:
                process.communicate(timeout=5)
            process.stdout.close()

    def test_confirmation_timeout_is_logged_and_never_authenticates(self):
        installer = ROOT / 'scripts/installer.sh'
        body = f'''set -e
source "{installer}"
INSTALL_ASSUME_YES=0
INSTALL_NEW_ENGINE=0
INSTALL_SUDO_DOCKER=0
INSTALL_SYSCTL=0
INSTALL_PACKAGES=(curl)
installer_authenticate() {{ echo MUST-NOT-AUTHENTICATE; return 99; }}
installer_apply
'''
        (self.project / 'scripts/deploy-project.sh').write_text(body)
        master, slave = pty.openpty()
        try:
            result = subprocess.run(['/bin/bash', '-c',
                                     'set -euo pipefail; source "$1/scripts/logging.sh"; run_deployment_logged "$2" 0',
                                     'test', str(ROOT), str(self.project)], stdin=slave,
                                    text=True, capture_output=True, timeout=5,
                                    env=dict(self.env, FINAL_PROJECT_CONFIRM_TIMEOUT_SECONDS='1'))
        finally:
            os.close(slave)
            os.close(master)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        log_text = self.logs()[0].read_text()
        self.assertIn('Confirmation timed out after 1 seconds', log_text)
        self.assertIn('no approval assumed', log_text)
        self.assertIn('Deployment exit_code=1', log_text)
        self.assertNotIn('MUST-NOT-AUTHENTICATE', log_text)
        self.assertIn(str(self.logs()[0]), result.stderr)

    def test_explicit_decline_is_still_cancelled(self):
        installer = ROOT / 'scripts/installer.sh'
        master, slave = pty.openpty()
        try:
            os.write(master, b'n\n')
            result = subprocess.run(['/bin/bash', '-c',
                                     'source "$1/scripts/installer.sh"; INSTALL_ASSUME_YES=0; installer_confirm',
                                     'test', str(ROOT)], stdin=slave, text=True,
                                    capture_output=True, timeout=3, env=self.env)
        finally:
            os.close(slave)
            os.close(master)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Installation cancelled', result.stderr)

    def test_actual_deployment_body_records_ansible_failure_without_cleanup(self):
        for name in ('common.sh', 'config.sh', 'checks.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, self.project / 'scripts' / name)
        shutil.copyfile(ROOT / '.env.example', self.project / '.env.example')
        (self.project / 'scripts/installer.sh').write_text('''installer_main() {
source "$PROJECT_ROOT/scripts/common.sh"
docker() { return 0; }
compose() { echo 'healthy services kept'; return 0; }
}
''')
        control = self.project / 'scripts/control.sh'
        control.write_text('''#!/usr/bin/env bash
[[ "$*" == *'ansible-playbook --verbose'* ]] || exit 98
printf '%s\\n' 'TASK [Create the K3s cluster]' 'fatal: [localhost]: FAILED! => {"rc": 11, "stdout": "stdout diagnostic", "stderr": "exact creation failure"}'
exit 2
''')
        control.chmod(0o755)
        (self.project / 'status.sh').write_text('echo MUST-NOT-RUN-STATUS\n')
        result = self.run_log((ROOT / 'scripts/deploy-project.sh').read_text(), 2)
        text = self.logs()[0].read_text()
        for expected in ('TASK [Create the K3s cluster]', '"rc": 11', 'stdout diagnostic',
                         'exact creation failure', '[stage=ansible] FAILED exit_code=2', 'Deployment exit_code=2'):
            self.assertIn(expected, text)
        self.assertIn('healthy services kept', text)
        self.assertNotIn('MUST-NOT-RUN-STATUS', text)
        self.assertFalse((self.project / '.state/operation.lock').exists())
        self.assertIn(str(self.logs()[0]), result.stderr)


if __name__ == '__main__':
    unittest.main()
