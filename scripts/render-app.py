"""Render the app manifest locally; this script never contacts Kubernetes."""
import os
import sys
from pathlib import Path
import yaml

def limits(prefix, defaults):
    result = {}
    for field, suffix in [('requests', 'REQUEST'), ('limits', 'LIMIT')]:
        previous = defaults.get(field, {})
        result[field] = {
            'cpu': os.environ.get(f'{prefix}_CPU_{suffix}_MILLICORES', previous.get('cpu', '200m').rstrip('m')) + 'm',
            'memory': os.environ.get(f'{prefix}_MEMORY_{suffix}_MB', previous.get('memory', '100Mi').removesuffix('Mi')) + 'Mi',
        }
    return result

fluent = sys.argv[1] == '--fluent-bit'
image = '' if fluent else sys.argv[1]
if not fluent and not image.startswith('final-project-web:'):
    raise SystemExit('Expected a project image')
resources = list(yaml.safe_load_all(Path(__file__).resolve().parents[1].joinpath('k3s/fluent-bit.yaml' if fluent else 'k3s/app.yaml').read_text()))
for resource in resources:
    if resource['kind'] == 'DaemonSet' and fluent:
        for container in resource['spec']['template']['spec']['containers']:
            container['resources'] = limits('FLUENT', container['resources'])
    if resource['kind'] == 'Deployment' and resource['metadata']['name'] == 'web-app':
        for container in resource['spec']['template']['spec']['containers']:
            if container['name'] == 'web-app':
                container['image'] = image
                container['resources'] = limits('APP', container['resources'])
yaml.safe_dump_all(resources, sys.stdout, sort_keys=False)
