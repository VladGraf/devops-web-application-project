#!/usr/bin/env bash
set -euo pipefail
# This script runs inside the controller. Never use a default kubectl context.
network_owner=$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' final-project_default)
[[ "$network_owner" == final-project ]] || { echo 'Unexpected project network owner' >&2; exit 1; }
nodes=$(docker ps -a --filter label=k3d.cluster=final-project --format '{{.Names}}' | sort)
expected=$(printf '%s\n' k3d-final-project-agent-0 k3d-final-project-agent-1 k3d-final-project-server-0 k3d-final-project-serverlb | sort)
[[ "$nodes" == "$expected" ]] || {
  echo 'Expected exactly 1 server, 2 workers and the k3d load balancer. No cluster changes made.' >&2
  exit 1
}
for node in $nodes; do
  docker inspect "$node" | jq -e '.[0].NetworkSettings.Networks | has("final-project_default")' >/dev/null
  if [[ "$node" != k3d-final-project-serverlb ]]; then
    docker inspect "$node" | jq -e '.[0].Config.Image == "rancher/k3s:v1.31.7-k3s1"' >/dev/null || {
      echo 'Existing cluster uses a different K3s image. No upgrade or replacement was attempted.' >&2; exit 1;
    }
  fi
done
docker inspect k3d-final-project-serverlb | jq -e --arg port "${NODE_PORT:-18080}" '
  .[0].HostConfig.PortBindings["30080/tcp"] |
  any(.HostIp == "127.0.0.1" and .HostPort == $port)' >/dev/null || {
  echo 'Existing project cluster has an incompatible NodePort mapping' >&2; exit 1;
}
if [[ -n "${API_PORT:-}" ]]; then
  docker inspect k3d-final-project-serverlb | jq -e --arg port "$API_PORT" '
    .[0].HostConfig.PortBindings["6443/tcp"] |
    any(.HostIp == "127.0.0.1" and .HostPort == $port)' >/dev/null || {
    echo 'Existing cluster API port differs from API_PORT. Keep its saved setting.' >&2; exit 1;
  }
fi
if [[ "${1:-verify}" == refresh ]]; then
  umask 077
  owner_uid=${FINAL_PROJECT_HOST_UID:?Missing invoking user UID}
  owner_gid=${FINAL_PROJECT_HOST_GID:?Missing invoking user GID}
  [[ "$owner_uid" =~ ^[0-9]+$ && "$owner_gid" =~ ^[0-9]+$ ]] || {
    echo 'Invalid invoking user UID/GID' >&2; exit 1;
  }
  state_dir=$(dirname "$KUBECONFIG")
  config_tmp=$(mktemp "$state_dir/kubeconfig.XXXXXX")
  trap 'rm -f "$config_tmp"' EXIT
  k3d kubeconfig get final-project > "$config_tmp"
  kubectl --kubeconfig "$config_tmp" config get-contexts -o name | grep -qx k3d-final-project
  chmod 600 "$config_tmp"
  chown "$owner_uid:$owner_gid" "$state_dir" "$config_tmp"
  mv "$config_tmp" "$KUBECONFIG"
fi
