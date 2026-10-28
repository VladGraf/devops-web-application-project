"""Offline installer tests. Package, privilege and service commands are mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLAN_MOCKS = r'''
docker_check() { docker "$@"; }
command() {
  if [[ "$1" == -v ]]; then
    if [[ "$2" == docker && "$MODE" == missing_docker ]]; then return 1; fi
    if [[ "$2" == docker && "$MODE" == conflict ]]; then return 1; fi
    if [[ "$2" == awk && "$MODE" == missing_awk ]]; then return 1; fi
    if [[ "$2" == dockerd || "$2" == containerd ]]; then return 1; fi
    return 0
  fi
  builtin command "$@"
}
installer_installed() {
  [[ "$1" == ca-certificates ]] && return 0
  [[ "$1" == docker-ce-cli && "$MODE" != missing_docker && "$MODE" != conflict ]] && return 0
  [[ "$1" == containerd && "$MODE" == conflict ]] && return 0
  [[ "$1" == docker-ce && "$MODE" == permission_denied ]] && return 0
  return 1
}
docker() {
  case "$1 ${2:-}" in
    'context inspect') echo unix:///var/run/docker.sock;;
    'info '*) [[ "$MODE" != permission_denied && "$MODE" != cli_only ]];;
    'version --format') if [[ "$MODE" == old_engine ]]; then echo 20.10.0; else echo 27.5.1; fi;;
    'compose version')
      [[ "$MODE" != missing_compose ]] || return 1
      if [[ "$MODE" == old_compose ]]; then echo 2.10.0; else echo 2.24.0; fi;;
    'buildx version') [[ "$MODE" != missing_buildx ]];;
    *) echo "Unexpected Docker call: $*" >&2; return 90;;
  esac
}
INSTALL_DOCKER_ENDPOINT=unix:///var/run/docker.sock
'''


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='final-project-installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.env = dict(os.environ)
        for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'FINAL_PROJECT_SUDO_DOCKER'):
            self.env.pop(key, None)

    def shell(self, code, success=True, mode='working'):
        script = 'set -euo pipefail; source "$1/scripts/installer.sh"; docker_check() { docker "$@"; }; ' + code
        result = subprocess.run(['/bin/bash', '-c', script, 'test', str(ROOT)],
                                env=dict(self.env, MODE=mode), text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def fixture(self, content):
        path = self.folder / 'os-release'
        path.write_text(content)
        return path

    def detect(self, content, success=True, arch='x86_64'):
        path = self.fixture(content)
        code = f'''uname() {{ if [[ "$1" == -s ]]; then echo Linux; else echo {arch}; fi; }}
apt-get() {{ return 97; }}
dpkg-query() {{ return 97; }}
installer_os '{path}'
printf '%s %s %s %s' "$HOST_ID" "$HOST_VERSION" "$HOST_SUITE" "$HOST_ARCH"'''
        return self.shell(code, success)

    def test_supported_os_versions_and_official_suites(self):
        for distro, version, suite in [('debian', '12', 'bookworm'), ('debian', '13', 'trixie'),
                                       ('ubuntu', '22.04', 'jammy'), ('ubuntu', '24.04', 'noble')]:
            with self.subTest(distro=distro, version=version):
                result = self.detect(f'ID={distro}\nVERSION_ID="{version}"\n')
                self.assertEqual(result.stdout, f'{distro} {version} {suite} amd64')

    def test_arm64_detection(self):
        self.assertIn('arm64', self.detect("ID='debian'\nVERSION_ID='13'\n", arch='aarch64').stdout)

    def test_unsupported_os_and_version_fail_clearly(self):
        for fixture in ('ID=fedora\nVERSION_ID=42\n', 'ID=ubuntu\nVERSION_ID=20.04\n', 'ID=linuxmint\nVERSION_ID=22\n'):
            self.assertIn('Unsupported operating system', self.detect(fixture, False).stderr)

    def test_unsupported_architecture(self):
        self.assertIn('Supported architectures', self.detect('ID=debian\nVERSION_ID=13\n', False, 'armv7l').stderr)

    def test_os_release_is_parsed_without_executing_it(self):
        marker = self.folder / 'must-not-exist'
        self.detect(f'ID=debian\nVERSION_ID=$(touch {marker})\n', False)
        self.assertFalse(marker.exists())

    def plan(self, mode, success=True):
        return self.shell(PLAN_MOCKS + '''
installer_plan
printf 'packages=%s\nnew=%s\naccess=%s\nbase=%s\n' "${INSTALL_PACKAGES[*]}" "$INSTALL_NEW_ENGINE" "$INSTALL_SUDO_DOCKER" "$INSTALL_BASE_MISSING"
''', success, mode)

    def test_working_software_is_not_reinstalled(self):
        result = self.plan('working')
        self.assertIn('packages=\nnew=0', result.stdout)

    def test_missing_engine_plans_official_docker_packages(self):
        result = self.plan('missing_docker')
        self.assertIn('docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin', result.stdout)
        self.assertIn('new=1', result.stdout)

    def test_cli_without_engine_is_detected(self):
        result = self.plan('cli_only')
        self.assertIn('packages=docker-ce containerd.io', result.stdout)
        self.assertIn('new=1', result.stdout)

    def test_only_missing_compose_is_planned(self):
        self.assertIn('packages=docker-compose-plugin\nnew=0', self.plan('missing_compose').stdout)

    def test_only_missing_buildx_is_planned(self):
        self.assertIn('packages=docker-buildx-plugin\nnew=0', self.plan('missing_buildx').stdout)

    def test_missing_base_dependency_is_detected(self):
        result = self.plan('missing_awk')
        self.assertIn('packages=gawk', result.stdout)
        self.assertIn('base=1', result.stdout)

    def test_permission_problem_is_not_treated_as_missing_engine(self):
        result = self.plan('permission_denied')
        self.assertIn('packages=\nnew=0\naccess=1', result.stdout)

    def test_conflicting_runtime_is_not_removed(self):
        self.assertIn('will not be replaced', self.plan('conflict', False).stderr)

    def test_timed_out_probe_is_not_treated_as_a_missing_dependency(self):
        result = self.shell(PLAN_MOCKS + 'docker_check() { echo \"mock Docker timeout\" >&2; return 124; }; installer_plan', False)
        self.assertIn('mock Docker timeout', result.stderr)

    def test_old_engine_and_compose_are_not_upgraded_silently(self):
        self.assertIn('Upgrade it separately', self.plan('old_engine', False).stderr)
        self.assertIn('Update it separately', self.plan('old_compose', False).stderr)

    def test_remote_docker_is_rejected(self):
        result = self.shell(PLAN_MOCKS + 'DOCKER_HOST=ssh://other-computer; installer_endpoint', False)
        self.assertIn('Remote Docker is unsupported', result.stderr)

    def test_declined_confirmation_prevents_any_privileged_command(self):
        result = self.shell(r'''
INSTALL_NEW_ENGINE=0; INSTALL_SUDO_DOCKER=0; INSTALL_SYSCTL=0
INSTALL_PACKAGES=(curl)
installer_confirm() { return 1; }
installer_authenticate() { echo 'MUST NOT AUTHENTICATE'; return 99; }
installer_root() { echo 'MUST NOT MUTATE'; return 99; }
installer_apply
''', False)
        self.assertNotIn('MUST NOT', result.stdout)

    def test_yes_is_explicit_noninteractive_consent(self):
        self.shell('INSTALL_ASSUME_YES=1; installer_confirm', True)
        self.assertIn('confirmation', self.shell('INSTALL_ASSUME_YES=0; installer_confirm', False).stderr)

    def test_approved_install_runs_only_the_planned_packages(self):
        result = self.shell(r'''
INSTALL_NEW_ENGINE=0; INSTALL_SUDO_DOCKER=0; INSTALL_SYSCTL=0
INSTALL_PACKAGES=(curl)
installer_confirm() { return 0; }
installer_authenticate() { return 0; }
installer_root() { printf 'MOCK ROOT: %s\n' "$*"; }
installer_safe_apt() { printf 'MOCK INSTALL: %s\n' "$*"; }
installer_apply
''')
        self.assertIn('MOCK INSTALL: curl', result.stdout)
        self.assertNotIn('systemctl', result.stdout)
        self.assertNotIn('docker-ce', result.stdout)

    def test_apt_removal_and_upgrade_plans_are_blocked(self):
        for plan in ('Remv containerd [1.0]', 'Inst docker-ce [27.5.1] (29.0.0 Docker)'):
            with self.subTest(plan=plan):
                code = f'''
installer_root() {{
  if [[ "$*" == *--simulate* ]]; then printf '%s\\n' '{plan}'; else echo 'MUST NOT INSTALL'; fi
}}
installer_safe_apt curl
'''
                result = self.shell(code, False)
                self.assertNotIn('MUST NOT INSTALL', result.stdout)

    def test_safe_apt_simulates_then_installs_without_removal_or_upgrade(self):
        result = self.shell(r'''
installer_root() {
  if [[ "$*" == *--simulate* ]]; then echo 'Inst curl (1.0 Debian)'; else echo "MOCK APPROVED: $*"; fi
}
installer_safe_apt curl
''')
        self.assertIn('--no-remove --no-upgrade --no-install-recommends install curl', result.stdout)
        self.assertIn('Acquire::https::Timeout=30', result.stdout)
        self.assertIn('Acquire::Retries=2', result.stdout)

    def test_old_docker_data_blocks_engine_install(self):
        result = self.shell('installer_root() { return 0; }; installer_new_engine_guard', False)
        self.assertIn('Existing runtime data path', result.stderr)

    def test_check_with_yes_never_installs_or_creates_state(self):
        project = self.folder / 'downloaded project'
        (project / 'scripts').mkdir(parents=True)
        (project / 'deploy.sh').write_text((ROOT / 'deploy.sh').read_text())
        (project / 'scripts/checks.sh').write_text((ROOT / 'scripts/checks.sh').read_text())
        (project / 'scripts/installer.sh').write_text((ROOT / 'scripts/installer.sh').read_text() + r'''
installer_environment() { return 0; }
docker() { return 1; }
docker_check() { docker "$@"; }
installer_os() { HOST_ID=debian; HOST_VERSION=13; HOST_SUITE=trixie; HOST_ARCH=amd64; }
installer_plan() {
  INSTALL_PACKAGES=(docker-ce); INSTALL_NEW_ENGINE=1; INSTALL_SUDO_DOCKER=0
  INSTALL_SYSCTL=0; INSTALL_DOCKER_REPO=1; INSTALL_BASE_MISSING=0
}
installer_apply() { echo 'MUST NOT INSTALL' >&2; return 99; }
''')
        (project / 'scripts/common.sh').write_text('ROOT="$PROJECT_ROOT"\n')
        (project / 'scripts/preflight.sh').write_text('check_resources() { :; }\ncheck_ports() { :; }\n')
        result = subprocess.run(['/bin/bash', str(project / 'deploy.sh'), '--check', '--yes'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('Check mode made no changes', result.stdout)
        self.assertNotIn('MUST NOT INSTALL', result.stderr)
        self.assertFalse((project / '.state').exists())

    def test_unsupported_daemon_settings_are_rejected_without_changing_them(self):
        code = r"""
docker() {
  case "$*" in
    *OSType*) echo linux;;
    *OperatingSystem*) echo Debian;;
    *SecurityOptions*) echo "$MODE";;
    *CgroupVersion*) echo 2;;
    *) return 99;;
  esac
}
installer_validate_daemon
"""
        for mode in ('rootless', 'userns'):
            self.assertIn('settings were not changed', self.shell(code, False, mode).stderr)
        self.shell(code, True, 'normal')

    def test_preflight_propagates_errors_when_called_in_a_condition(self):
        result = self.shell(r"""
source "$1/scripts/common.sh"
source "$1/scripts/preflight.sh"
check_host() { return 1; }
check_compose_ownership() { echo 'MUST NOT CONTINUE'; }
if preflight; then exit 99; else echo 'EXPECTED FAILURE'; fi
""")
        self.assertIn('EXPECTED FAILURE', result.stdout)
        self.assertNotIn('MUST NOT CONTINUE', result.stdout)

    def test_invalid_config_stops_bootstrap_even_in_a_condition(self):
        result = self.shell(r"""
export WEB_PORT=5601
if source "$1/scripts/common.sh"; then echo 'MUST NOT CONTINUE'; exit 99; fi
""")
        self.assertIn('conflicts', result.stderr)
        self.assertNotIn('MUST NOT CONTINUE', result.stdout)

    def test_ready_check_mode_does_not_deploy(self):
        project = self.folder / 'ready-project'
        (project / 'scripts').mkdir(parents=True)
        (project / 'deploy.sh').write_text((ROOT / 'deploy.sh').read_text())
        (project / 'scripts/checks.sh').write_text((ROOT / 'scripts/checks.sh').read_text())
        (project / 'scripts/installer.sh').write_text((ROOT / 'scripts/installer.sh').read_text() + r"""
installer_environment() { return 0; }
docker() { return 1; }
docker_check() { docker "$@"; }
installer_os() { HOST_ID=debian; HOST_VERSION=13; HOST_SUITE=trixie; HOST_ARCH=amd64; }
installer_plan() {
  INSTALL_PACKAGES=(); INSTALL_NEW_ENGINE=0; INSTALL_SUDO_DOCKER=0
  INSTALL_SYSCTL=0; INSTALL_DOCKER_REPO=0; INSTALL_BASE_MISSING=0
}
installer_apply() { echo 'MUST NOT INSTALL' >&2; return 99; }
""")
        (project / 'scripts/common.sh').write_text('ROOT="$PROJECT_ROOT"\n')
        (project / 'scripts/preflight.sh').write_text('check_resources() { :; }\ncheck_ports() { :; }\npreflight() { :; }\n')
        result = subprocess.run(['/bin/bash', str(project / 'deploy.sh'), '--check', '--yes'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('no deployment started', result.stdout)
        self.assertNotIn('MUST NOT INSTALL', result.stderr)
        self.assertFalse((project / '.state').exists())


if __name__ == '__main__':
    unittest.main()
