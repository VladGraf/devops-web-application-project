"""Offline status checks. No real HTTP, Docker or Kubernetes calls are made."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ['FINAL_PROJECT_STATUS_MODE']
if name == 'bash':
    assert args == ['scripts/cluster.sh', 'verify'], args
elif name == 'sleep':
    pass
elif name == 'docker':
    assert args[0] == 'inspect', args
    print('running healthy')
elif name == 'kubectl':
    assert args[:2] == ['--context', 'k3d-final-project'], args
    if 'get' in args and 'deployment' in args:
        print(json.dumps({'spec': {'replicas': 3}, 'status': {
            'readyReplicas': 3, 'updatedReplicas': 3, 'availableReplicas': 3}}))
    elif 'get' in args and 'daemonset' in args:
        print(json.dumps({'status': {'desiredNumberScheduled': 3,
            'numberReady': 2 if mode == 'collector_failure' else 3, 'numberAvailable': 3}}))
elif name == 'curl':
    url = args[-1]
    if '/readyz' in url and mode == 'http_failure':
        sys.exit(22)
    if '/_search' in url:
        query = json.loads(args[args.index('-d') + 1])
        assert 'final-project-check-' in json.dumps(query), query
        print(json.dumps({'hits': {'total': {'value': 0 if mode == 'missing_logs' else 1}}}))
    elif '/_cluster/health' in url:
        print('{"status":"yellow"}')
    elif ':5601/api/status' in url:
        print('{"status":{"overall":{"level":"available"}}}')
    elif '/api/status' in url:
        print('{"status":"healthy"}')
    else:
        print('OK')
else:
    raise AssertionError(name)
'''


class StatusChecks(unittest.TestCase):
    def check_mode(self, mode, success, message=''):
        with tempfile.TemporaryDirectory(prefix='final-project-status-test-') as folder:
            folder = Path(folder)
            mock = folder / 'mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ('docker', 'kubectl', 'curl', 'bash', 'sleep'):
                (folder / name).symlink_to(mock)
            env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}', FINAL_PROJECT_STATUS_MODE=mode)
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/check-status.sh')],
                                    env=env, text=True, capture_output=True)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode == 0, success, output)
            self.assertIn(message, output)

    def test_healthy_services_and_log_delivery(self):
        self.check_mode('healthy', True, 'PASS: request reached Elasticsearch')

    def test_http_error_returns_failure(self):
        self.check_mode('http_failure', False, 'FAIL: HTTP check:')

    def test_missing_log_returns_failure(self):
        self.check_mode('missing_logs', False, 'FAIL: Test request did not reach Elasticsearch')

    def test_missing_collector_returns_failure(self):
        self.check_mode('collector_failure', False, 'FAIL: Expected 3 Ready Fluent Bit collectors')


if __name__ == '__main__':
    unittest.main()
