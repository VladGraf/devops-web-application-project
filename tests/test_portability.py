"""Offline configuration and preflight tests in a relocated project directory."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PortabilityChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='final-project-portability-')
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / 'another directory' / 'downloaded-project'
        (self.project / 'scripts').mkdir(parents=True)
        for name in ('config.sh', 'common.sh', 'preflight.sh', 'checks.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, self.project / 'scripts' / name)
        shutil.copyfile(ROOT / '.env.example', self.project / '.env.example')
        self.env = dict(os.environ)
        for line in (ROOT / '.env.example').read_text().splitlines():
            if line and not line.startswith('#'):
                self.env.pop(line.split('=')[0], None)

    def shell(self, code, success=True, env=None):
        command = f'set -euo pipefail; source "$1/scripts/common.sh"; docker_check() {{ docker "$@"; }}; {code}'
        result = subprocess.run(['/bin/bash', '-c', command, 'test', str(self.project)],
                                cwd='/tmp', env=env or self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_defaults_from_another_directory_with_spaces(self):
        result = self.shell('printf "%s %s" "$WEB_PORT" "$API_PORT"')
        self.assertEqual(result.stdout, '8088 16443')

    def test_environment_overrides_file_and_saved_values(self):
        (self.project / '.state').mkdir()
        (self.project / '.state/settings.env').write_text('WEB_PORT=8090\nES_PORT=19201\n')
        (self.project / '.env').write_text('WEB_PORT=8091\n')
        result = self.shell('printf "%s %s" "$WEB_PORT" "$ES_PORT"', env=dict(self.env, WEB_PORT='8092'))
        self.assertEqual(result.stdout, '8092 19201')

    def test_saved_settings_round_trip_without_env_file(self):
        self.shell('mkdir .state; save_config', env=dict(self.env, WEB_PORT='8093'))
        self.assertEqual(self.shell('printf "%s" "$WEB_PORT"').stdout, '8093')

    def test_duplicate_ports_are_rejected(self):
        (self.project / '.env').write_text('WEB_PORT=5601\n')
        self.assertIn('conflicts', self.shell(':', success=False).stderr)

    def test_invalid_heap_is_rejected(self):
        (self.project / '.env').write_text('ES_HEAP_MB=1500\n')
        self.assertIn('twice their heaps', self.shell(':', success=False).stderr)

    def test_unknown_setting_is_rejected(self):
        (self.project / '.env').write_text('UNKNOWN_PORT=1234\n')
        self.assertIn('Unknown setting', self.shell(':', success=False).stderr)

    def test_shell_code_in_configuration_is_never_executed(self):
        marker = self.project / 'must-not-exist'
        (self.project / '.env').write_text(f'WEB_PORT=$(touch "{marker}")\n')
        self.shell(':', success=False)
        self.assertFalse(marker.exists())

    def test_owned_listening_ports_allow_repeat_deployment(self):
        self.shell('''source scripts/preflight.sh
port_is_listening() { return 0; }
port_is_project_owned() { return 0; }
docker() { return 0; }
check_ports''')

    def test_existing_k3d_load_balancer_node_port_ownership(self):
        code = '''source scripts/preflight.sh
port_is_listening() { [[ "$1" == 18080 ]]; }
docker() {
  case "$1" in
    ps) printf 'k3d-final-project-serverlb\\n';;
    inspect)
      [[ "${@: -1}" == k3d-final-project-serverlb ]] || return 1
      if [[ "$*" == *k3d.cluster* ]]; then
        printf '%s\\n' "$FINAL_PROJECT_TEST_PORT_OWNER"
      elif [[ "$FINAL_PROJECT_TEST_PORT_OWNER" == other-process ]]; then
        printf '16443\\n'
      else
        printf '18080\\n16443\\n'
      fi;;
    *) return 99;;
  esac
}
check_ports'''
        for owner in ('final-project', 'other-project', 'other-process'):
            with self.subTest(owner=owner):
                result = self.shell(code, success=owner == 'final-project',
                                    env=dict(self.env, FINAL_PROJECT_TEST_PORT_OWNER=owner))
                if owner != 'final-project':
                    self.assertIn('NODE_PORT=18080 is already in use', result.stderr)

    def test_unrelated_listening_port_is_rejected(self):
        result = self.shell('''source scripts/preflight.sh
port_is_listening() { return 0; }
port_is_project_owned() { return 1; }
docker() { echo 'DOCKER MUST NOT RUN' >&2; exit 99; }
check_ports''', success=False)
        self.assertIn('already in use', result.stderr)
        self.assertNotIn('DOCKER MUST NOT RUN', result.stderr)

    def test_unrelated_docker_port_reservation_is_rejected(self):
        result = self.shell('''source scripts/preflight.sh
port_is_listening() { return 1; }
port_is_project_owned() { [[ "$1" == other-project-nginx ]]; }
docker() { printf 'other-project-nginx'; }
check_ports''', success=False)
        self.assertIn('reserved by another container', result.stderr)

    def test_custom_application_and_collector_limits_render(self):
        env = dict(self.env, APP_MEMORY_LIMIT_MB='256', FLUENT_MEMORY_LIMIT_MB='160')
        for arg, kind, prefix, expected in [('final-project-web:test', 'Deployment', 'APP', '256Mi'),
                                            ('--fluent-bit', 'DaemonSet', 'FLUENT', '160Mi')]:
            result = subprocess.run(['python3', str(ROOT / 'scripts/render-app.py'), arg],
                                    env=env, capture_output=True, text=True, check=True)
            import yaml
            resources = list(yaml.safe_load_all(result.stdout))
            workload = next(r for r in resources if r['kind'] == kind)
            self.assertEqual(workload['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'], expected)

    def test_version_minimum_comparison(self):
        self.shell('version_at_least 27.5.1 27.5.1; version_at_least 29.0.0 27.5.1; ! version_at_least 26.1.0 27.5.1')


if __name__ == '__main__':
    unittest.main()
