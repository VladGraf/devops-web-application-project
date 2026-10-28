"""Offline timeout checks use a fake Docker executable, never the daemon."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DockerDeadlineChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='final-project-checks-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        docker = self.folder / 'docker'
        docker.write_text('''#!/usr/bin/env bash
case "$FINAL_PROJECT_TEST_MODE" in
  hang) exec sleep 5;;
  failure) echo 'mock connection refused' >&2; exit 42;;
  *) printf 'mock Docker %s\\n' "$*";;
esac
''')
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.folder}:{os.environ["PATH"]}',
                        FINAL_PROJECT_DOCKER_CHECK_TIMEOUT_SECONDS='1', FINAL_PROJECT_SUDO_DOCKER='0')

    def run_check(self, mode):
        start = time.monotonic()
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1/scripts/checks.sh"; docker_check info', 'test', str(ROOT)],
                                env=dict(self.env, FINAL_PROJECT_TEST_MODE=mode),
                                text=True, capture_output=True, timeout=4)
        return result, time.monotonic()-start

    def test_hanging_client_times_out_without_touching_a_daemon(self):
        result, elapsed = self.run_check('hang')
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertIn('timed out after 1 seconds (exit_code=124)', result.stderr)
        self.assertLess(elapsed, 4)

    def test_docker_timeout_error_and_exit_code_reach_the_private_log(self):
        scripts = self.folder / 'scripts'
        scripts.mkdir()
        shutil.copyfile(ROOT / 'scripts/redact.awk', scripts / 'redact.awk')
        (scripts / 'deploy-project.sh').write_text(f'set -e\nsource "{ROOT}/scripts/checks.sh"\ndocker_check info\n')
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1/scripts/logging.sh"; run_deployment_logged "$2" 0',
                                 'test', str(ROOT), str(self.folder)],
                                env=dict(self.env, FINAL_PROJECT_TEST_MODE='hang'),
                                text=True, capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        log = next((self.folder / '.state/logs').glob('*.log'))
        text = log.read_text()
        self.assertIn('Docker info check timed out', text)
        self.assertIn('exit_code=124', text)
        self.assertIn(str(log), result.stderr)

    def test_successful_check_still_works(self):
        result, _ = self.run_check('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mock Docker info', result.stdout)

    def test_non_timeout_error_code_is_preserved(self):
        result, _ = self.run_check('failure')
        self.assertEqual(result.returncode, 42)
        self.assertIn('mock connection refused', result.stderr)
        self.assertNotIn('timed out', result.stderr)


if __name__ == '__main__':
    unittest.main()
