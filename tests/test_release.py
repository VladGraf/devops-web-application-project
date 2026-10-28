"""Offline release checks. All Docker, k3d and Kubernetes commands are mocked."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
import yaml
p = Path(os.environ['FINAL_PROJECT_TEST_STATE'])
s = json.loads(p.read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
s['calls'].append([tool, *args])
code = 0
out = ''
if tool == 'bash':
    assert args == ['scripts/cluster.sh', 'verify'], args
elif tool == 'k3d':
    assert args[:2] == ['image', 'import'], args
elif tool == 'docker':
    if args[:2] == ['image', 'inspect']:
        image = args[-1]
        if image not in s['images']:
            code = 1
        else:
            out = s['images'][image] if '-f' in args else '[]'
    elif args[0] == 'build':
        image = args[args.index('-t') + 1]
        label = args[args.index('--label') + 1].split('=', 1)[1]
        s['images'][image] = label
    else:
        raise AssertionError(args)
elif tool == 'kubectl':
    assert args[:4] == ['--context', 'k3d-final-project', '-n', 'final-project'] or args[:2] == ['--context', 'k3d-final-project'], args
    args = args[4:] if args[2:4] == ['-n', 'final-project'] else args[2:]
    if args[:2] == ['get', 'deployment']:
        out = json.dumps(s['deployment']) if s['deployment'] else ''
    elif args[:2] == ['rollout', 'status']:
        deployment = s['deployment']
        current = deployment['spec']['template']['spec']['containers'][0]['image']
        failed = any(c.get('reason') == 'ProgressDeadlineExceeded'
                     for c in deployment.get('status', {}).get('conditions', []))
        if failed or (s.get('fail_target') and current != s['original']):
            code = 1
        else:
            generation = deployment['metadata'].setdefault('generation', 1)
            deployment['status'] = {'observedGeneration': generation, 'updatedReplicas': 3,
                                    'readyReplicas': 3, 'availableReplicas': 3,
                                    'conditions': [{'type': 'Progressing', 'status': 'True'}]}
    elif args[:2] == ['set', 'image']:
        container = s['deployment']['spec']['template']['spec']['containers'][0]
        image = args[-1].split('=', 1)[1]
        if container['image'] != image:
            s['deployment']['status'] = {}
        container['image'] = image
    elif args[:2] == ['rollout', 'restart']:
        assert args[2:] == ['deployment/web-app'], args
        s['deployment']['status'] = {}
    elif args[0] == 'apply':
        docs = list(yaml.safe_load_all(sys.stdin.read()))
        deployment = next(d for d in docs if d['kind'] == 'Deployment')
        deployment['metadata']['generation'] = (s['deployment']['metadata'].get('generation', 0) if s['deployment'] else 0) + 1
        if s['deployment']:
            deployment['metadata']['annotations'] = s['deployment']['metadata'].get('annotations', {})
            if deployment['spec']['template'] == s['deployment']['spec']['template']:
                deployment['status'] = s['deployment'].get('status', {})
                deployment['metadata']['generation'] = s['deployment']['metadata']['generation']
        s['deployment'] = deployment
    elif args[0] == 'annotate':
        annotations = s['deployment']['metadata'].setdefault('annotations', {})
        for arg in args:
            if arg.startswith('final-project.io/'):
                key, value = arg.split('=', 1)
                annotations[key] = value
    else:
        raise AssertionError(args)
else:
    raise AssertionError(tool)
p.write_text(json.dumps(s))
print(out, end='')
sys.exit(code)
'''


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='final-project-test-')
        self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)
        mock = folder / 'mock'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ('docker', 'kubectl', 'k3d', 'bash'):
            (folder / name).symlink_to(mock)
        self.state_file = folder / 'state.json'
        self.env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}',
                        FINAL_PROJECT_TEST_STATE=str(self.state_file))
        self.save({'deployment': None, 'images': {}, 'calls': []})

    def save(self, state):
        self.state_file.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_file.read_text())

    def run_release(self, action, success=True):
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/release.sh'), action],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return self.state()

    def seed(self, current='final-project-web:v2-current', previous='final-project-web:v2-previous'):
        docs = list(yaml.safe_load_all((ROOT / 'k3s/app.yaml').read_text()))
        deployment = next(d for d in docs if d['kind'] == 'Deployment')
        deployment['spec']['template']['spec']['containers'][0]['image'] = current
        deployment['metadata']['generation'] = 1
        deployment['status'] = {'observedGeneration': 1, 'updatedReplicas': 3, 'readyReplicas': 3, 'availableReplicas': 3}
        deployment['metadata']['annotations'] = {
            'final-project.io/current-image': current,
            'final-project.io/previous-image': previous,
        }
        self.save({'deployment': deployment, 'images': {current: '', previous: ''},
                   'original': current, 'calls': []})

    @staticmethod
    def image(state):
        return state['deployment']['spec']['template']['spec']['containers'][0]['image']

    def test_failed_deployment_retry_applies_before_waiting_and_keeps_history(self):
        for known_working_release in (False, True):
            with self.subTest(known_working_release=known_working_release):
                self.seed(current='final-project-web:v1-working', previous='final-project-web:v1-previous')
                state = self.state()
                deployment = state['deployment']
                broken = 'final-project-web:v2-broken' if known_working_release else 'final-project-web:v1-broken'
                deployment['spec']['template']['spec']['containers'][0]['image'] = broken
                deployment['spec']['template']['spec']['containers'][0]['securityContext'].pop('runAsUser', None)
                deployment['status'] = {'observedGeneration': 1, 'readyReplicas': 0,
                                        'conditions': [{'type': 'Progressing', 'status': 'False',
                                                        'reason': 'ProgressDeadlineExceeded'}]}
                if not known_working_release:
                    deployment['metadata']['annotations'] = {}
                self.save(state)
                recovered = self.run_release('deploy')
                target = self.image(recovered)
                version = 'v2' if known_working_release else 'v1'
                self.assertRegex(target, rf'^final-project-web:{version}-[0-9a-f]{{64}}$')
                self.assertNotEqual(target, broken)
                context = recovered['deployment']['spec']['template']['spec']['containers'][0]['securityContext']
                self.assertEqual(context['runAsUser'], 10001)
                calls = recovered['calls']
                applied = next(i for i, c in enumerate(calls) if c[0] == 'kubectl' and 'apply' in c)
                waited = next(i for i, c in enumerate(calls) if c[0] == 'kubectl' and 'rollout' in c)
                self.assertLess(applied, waited)
                self.assertEqual(sum(c[:2] == ['docker', 'build'] for c in calls), 1)
                previous = recovered['deployment']['metadata']['annotations']['final-project.io/previous-image']
                self.assertEqual(previous, 'final-project-web:v1-working' if known_working_release else '')
                if known_working_release:
                    rolled_back = self.run_release('rollback')
                    self.assertEqual(self.image(rolled_back), 'final-project-web:v1-working')
                    self.assertEqual(rolled_back['deployment']['metadata']['annotations']['final-project.io/previous-image'], target)

    def test_first_deploy_and_repeat_keep_release(self):
        first = self.run_release('deploy')
        image = self.image(first)
        self.assertRegex(image, r'^final-project-web:v1-[0-9a-f]{64}$')
        second = self.run_release('deploy')
        self.assertEqual(self.image(second), image)
        self.assertEqual(sum(c[:2] == ['docker', 'build'] for c in second['calls']), 1)
        self.assertFalse(any('restart' in c for c in second['calls']))

    def test_unchanged_failed_retry_restarts_only_web_app(self):
        self.run_release('deploy')
        state = self.state()
        state['calls'] = []
        state['deployment']['status'] = {'conditions': [
            {'type': 'Progressing', 'status': 'False', 'reason': 'ProgressDeadlineExceeded'}]}
        self.save(state)
        recovered = self.run_release('deploy')
        calls = recovered['calls']
        restart = next(i for i, c in enumerate(calls) if 'restart' in c)
        apply = next(i for i, c in enumerate(calls) if 'apply' in c)
        wait = next(i for i, c in enumerate(calls) if 'status' in c)
        self.assertLess(apply, restart)
        self.assertLess(restart, wait)
        self.assertEqual(calls[restart][-1], 'deployment/web-app')
        self.assertFalse(any(c[:2] == ['docker', 'build'] for c in calls))

    def test_failed_current_can_rollback_without_waiting_first(self):
        self.seed()
        state = self.state()
        state['deployment']['status'] = {'conditions': [
            {'type': 'Progressing', 'status': 'False', 'reason': 'ProgressDeadlineExceeded'}]}
        self.save(state)
        recovered = self.run_release('rollback')
        calls = recovered['calls']
        changed = next(i for i, c in enumerate(calls) if 'set' in c)
        wait = next(i for i, c in enumerate(calls) if 'rollout' in c)
        self.assertLess(changed, wait)
        self.assertEqual(self.image(recovered), 'final-project-web:v2-previous')
        self.assertEqual(recovered['deployment']['metadata']['annotations']['final-project.io/previous-image'],
                         'final-project-web:v2-current')

    def test_deploy_preserves_current_and_previous(self):
        self.seed()
        state = self.run_release('deploy')
        self.assertEqual(self.image(state), 'final-project-web:v2-current')
        self.assertEqual(state['deployment']['metadata']['annotations']['final-project.io/previous-image'],
                         'final-project-web:v2-previous')

    def test_update_is_immutable_and_repeat_is_noop(self):
        self.seed()
        first = self.run_release('update')
        self.assertRegex(self.image(first), r'^final-project-web:v2-[0-9a-f]{64}$')
        second = self.run_release('update')
        self.assertEqual(self.image(first), self.image(second))
        self.assertEqual(sum(c[:2] == ['docker', 'build'] for c in second['calls']), 1)
        self.assertEqual(sum(c[0] == 'kubectl' and 'set' in c for c in second['calls']), 1)
        self.assertEqual(second['deployment']['metadata']['annotations']['final-project.io/previous-image'],
                         'final-project-web:v2-current')

    def test_rollback_swaps_previous_working_images(self):
        self.seed()
        state = self.run_release('rollback')
        self.assertEqual(self.image(state), 'final-project-web:v2-previous')
        self.assertEqual(state['deployment']['metadata']['annotations']['final-project.io/previous-image'],
                         'final-project-web:v2-current')

    def test_failed_update_restores_current_without_committing_history(self):
        self.seed()
        state = self.state()
        state['fail_target'] = True
        self.save(state)
        state = self.run_release('update', success=False)
        self.assertEqual(self.image(state), 'final-project-web:v2-current')
        self.assertEqual(state['deployment']['metadata']['annotations']['final-project.io/previous-image'],
                         'final-project-web:v2-previous')

    def test_missing_previous_release_fails_safely(self):
        self.seed(previous='')
        state = self.run_release('rollback', success=False)
        self.assertEqual(self.image(state), 'final-project-web:v2-current')

    def test_rollback_validates_recorded_image_before_changing_deployment(self):
        previous = 'final-project-web:v1-' + 'a' * 64
        for label in ('a' * 64, 'wrong-label', None):
            with self.subTest(label=label):
                self.seed(previous=previous)
                state = self.state()
                if label is None:
                    del state['images'][previous]
                else:
                    state['images'][previous] = label
                self.save(state)
                result = self.run_release('rollback', success=(label == 'a' * 64))
                self.assertEqual(self.image(result), previous if label == 'a' * 64 else 'final-project-web:v2-current')
                if label != 'a' * 64:
                    self.assertFalse(any(c[0] == 'k3d' or 'set' in c for c in result['calls']))

    def test_manual_image_change_is_rejected(self):
        self.seed()
        state = self.state()
        state['deployment']['metadata']['annotations']['final-project.io/current-image'] = 'final-project-web:other'
        self.save(state)
        state = self.run_release('update', success=False)
        self.assertFalse(any(c[:2] == ['docker', 'build'] for c in state['calls']))


if __name__ == '__main__':
    unittest.main()
