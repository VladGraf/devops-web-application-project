"""Offline checks that reject incompatible clusters before any mutation."""
import os
from pathlib import Path
import subprocess
import tempfile
import stat
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
if Path(sys.argv[0]).name == 'k3d':
    assert sys.argv[1:] == ['kubeconfig', 'get', 'final-project']
    print('apiVersion: v1\nkind: Config')
    sys.exit(0)
if Path(sys.argv[0]).name == 'kubectl':
    assert sys.argv[1] == '--kubeconfig'
    assert sys.argv[3:] == ['config', 'get-contexts', '-o', 'name']
    print('k3d-final-project')
    sys.exit(0)
mode = os.environ['FINAL_PROJECT_CLUSTER_MODE']
args = sys.argv[1:]
if args[:2] == ['network', 'inspect']:
    print('another-project' if mode == 'foreign_network' else 'final-project')
elif args[0] == 'ps':
    print('k3d-final-project-server-0\nk3d-final-project-agent-0\nk3d-final-project-serverlb')
    if mode != 'missing_worker':
        print('k3d-final-project-agent-1')
elif args[0] == 'inspect':
    if '-f' in args:
        memory = 2048 if 'server-0' in args[-1] else 1536
        if mode == 'unlimited': memory = 0
        print(memory * 1048576)
        sys.exit(0)
    print(json.dumps([{
        'NetworkSettings': {'Networks': {'final-project_default': {}}},
        'Config': {'Image': 'rancher/k3s:v1.33.0-k3s1' if mode == 'wrong_version' else 'rancher/k3s:v1.31.7-k3s1'},
        'HostConfig': {'PortBindings': {'30080/tcp': [{
            'HostIp': '0.0.0.0' if mode == 'wrong_mapping' else '127.0.0.1',
            'HostPort': '18080'}], '6443/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '16443'}]}}
    }]))
else:
    raise AssertionError('Unexpected command: ' + str(args))
'''


class ClusterChecks(unittest.TestCase):
    def check_mode(self, mode, success, configured=False):
        with tempfile.TemporaryDirectory(prefix='final-project-cluster-test-') as folder:
            folder = Path(folder)
            mock = folder / 'docker'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}', FINAL_PROJECT_CLUSTER_MODE=mode)
            if configured:
                env.update(API_PORT='16443', NODE_PORT='18080', SERVER_MEMORY_MB='2048', WORKER_MEMORY_MB='1536')
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/cluster.sh'), 'verify'],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_kubeconfig_refresh_preserves_invoking_user_ownership_and_mode(self):
        with tempfile.TemporaryDirectory(prefix='final-project-kubeconfig-test-') as folder:
            folder = Path(folder)
            for name in ('docker', 'k3d', 'kubectl'):
                executable = folder / name
                executable.write_text(MOCK)
                executable.chmod(0o755)
            state_dir = folder / '.state'
            state_dir.mkdir(mode=0o700)
            config = state_dir / 'kubeconfig'
            config.write_text('old config')
            config.chmod(0o644)
            uid = os.getuid() if os.getuid() else 65534
            gid = os.getgid() if os.getuid() else 65534
            env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}',
                       FINAL_PROJECT_CLUSTER_MODE='valid', KUBECONFIG=str(config),
                       FINAL_PROJECT_HOST_UID=str(uid), FINAL_PROJECT_HOST_GID=str(gid),
                       NODE_PORT='18080', API_PORT='16443')
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/cluster.sh'), 'refresh'],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(config.read_text(), 'apiVersion: v1\nkind: Config\n')
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
            self.assertEqual((config.stat().st_uid, config.stat().st_gid), (uid, gid))
            self.assertEqual((state_dir.stat().st_uid, state_dir.stat().st_gid), (uid, gid))

    def test_expected_cluster_is_accepted(self):
        self.check_mode('valid', True)

    def test_configured_api_and_node_limits_are_accepted(self):
        self.check_mode('valid', True, configured=True)

    def test_unlimited_node_memory_is_accepted(self):
        command = (ROOT / 'ansible/deploy.yml').read_text()
        self.assertNotIn('--servers-memory', command)
        self.assertNotIn('--agents-memory', command)
        self.check_mode('unlimited', True, configured=True)

    def test_incompatible_k3s_version_is_rejected(self):
        self.check_mode('wrong_version', False)

    def test_missing_worker_is_rejected(self):
        self.check_mode('missing_worker', False)

    def test_foreign_network_is_rejected(self):
        self.check_mode('foreign_network', False)

    def test_incompatible_port_mapping_is_rejected(self):
        self.check_mode('wrong_mapping', False)


if __name__ == '__main__':
    unittest.main()
