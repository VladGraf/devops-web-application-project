#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
check_host
check_compose_ownership
lock_project
echo 'This deletes only the Final Project cluster and its Elasticsearch data.'
read -r -p 'Type DELETE to continue: ' confirm
[[ "$confirm" == DELETE ]] || exit 1
cluster_nodes=$(docker_check ps -a --filter label=k3d.cluster=final-project --format '{{.Names}}')
if [[ -n "$cluster_nodes" ]]; then
  ./scripts/control.sh bash scripts/cluster.sh verify
  ./scripts/control.sh k3d cluster delete final-project
else
  echo 'Project cluster is absent; cleaning up project-owned Compose resources only.'
fi
# Delete only known Compose services. Keep the shared network if other containers use it.
compose rm --stop --force nginx logstash kibana elasticsearch
if docker volume inspect final-project_esdata >/dev/null 2>&1; then
  docker volume rm final-project_esdata
fi
# No network pruning and no removal of other clusters or images.
rm -f .state/kubeconfig
echo 'Project removed. The shared network and release images were kept.'
