"""Offline recovery checks; all host and infrastructure commands are mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RecoveryChecks(unittest.TestCase):
    def test_repository_resumes_matching_files_and_rejects_conflicts(self):
        text = (ROOT / 'scripts/installer.sh').read_text()
        function = text[text.index('installer_repository()'):text.index('installer_new_engine_guard()')]
        for mode in ('key_only', 'source_only', 'complete', 'foreign_source', 'foreign_key', 'other_repo'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                apt = Path(folder) / 'apt'
                sources = apt / 'sources.list.d'
                sources.mkdir(parents=True)
                key = apt / 'keyrings/final-project-docker.asc'
                key.parent.mkdir()
                source = sources / 'final-project-docker.sources'
                expected = ('# final-project managed Docker repository\nTypes: deb\n'
                            'URIs: https://download.docker.com/linux/debian\nSuites: trixie\n'
                            f'Components: stable\nArchitectures: amd64\nSigned-By: {key}\n')
                official = '-----BEGIN PGP PUBLIC KEY BLOCK-----\nmock official key\n'
                if mode != 'source_only':
                    key.write_text('foreign key' if mode == 'foreign_key' else official)
                if mode != 'key_only':
                    source.write_text('foreign source' if mode == 'foreign_source' else expected)
                if mode == 'other_repo':
                    (sources / 'unrelated.list').write_text('deb https://download.docker.com/linux/debian trixie stable\n')
                before = {p: p.read_bytes() for p in apt.rglob('*') if p.is_file()}
                script = function.replace('/etc/apt', str(apt)) + r'''
installer_error() { echo "$*" >&2; }
installer_root() { "$@"; }
apt-cache() { return 0; }
curl() { printf '%s' "$MOCK_KEY" > "${!#}"; }
HOST_ID=debian; HOST_SUITE=trixie; HOST_ARCH=amd64
installer_repository
'''
                result = subprocess.run(['/bin/bash', '-c', script], text=True, capture_output=True,
                                        env=dict(os.environ, MOCK_KEY=official))
                good = mode in ('key_only', 'source_only', 'complete')
                self.assertEqual(result.returncode == 0, good, result.stdout + result.stderr)
                if good:
                    self.assertEqual(source.read_text(), expected)
                    self.assertEqual(key.read_text(), official)
                else:
                    self.assertEqual({p: p.read_bytes() for p in apt.rglob('*') if p.is_file()}, before)

    def test_cleanup_skips_absent_cluster_and_rejects_invalid_existing_cluster(self):
        # Exercise the script body with every external action replaced by a shell mock.
        body = (ROOT / 'destroy.sh').read_text().split('check_host\n', 1)[1]
        for mode in ('absent', 'valid', 'invalid', 'probe_error'):
            with self.subTest(mode=mode):
                script = r'''
set -euo pipefail
check_compose_ownership() { echo ownership; }
lock_project() { :; }
docker_check() {
  [[ "$MODE" != probe_error ]] || return 124
  [[ "$MODE" == absent ]] || echo k3d-final-project-server-0
}
control() {
  echo "control $*"
  if [[ "$*" == *verify && "$MODE" == invalid ]]; then return 1; fi
}
compose() { echo "compose $*"; }
docker() { echo "docker $*"; }
rm() { echo "mock rm $*"; }
''' + body.replace('./scripts/control.sh', 'control')
                result = subprocess.run(['/bin/bash', '-c', script], input='DELETE\n', text=True,
                                        capture_output=True, env=dict(os.environ, MODE=mode))
                good = mode in ('absent', 'valid')
                self.assertEqual(result.returncode == 0, good, result.stdout + result.stderr)
                self.assertEqual('compose rm --stop --force nginx logstash kibana elasticsearch' in result.stdout, good)
                self.assertEqual('control k3d cluster delete final-project' in result.stdout, mode == 'valid')
                self.assertEqual('docker volume rm final-project_esdata' in result.stdout, good)
                if mode == 'absent':
                    self.assertNotIn('control ', result.stdout)


if __name__ == '__main__':
    unittest.main()
