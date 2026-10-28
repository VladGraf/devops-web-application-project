#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
check_host
mkdir -p "$ROOT/.state"
chmod 700 "$ROOT/.state"
fingerprint=$(sha256sum controller/Dockerfile controller/requirements.txt | sha256sum | cut -d ' ' -f1)
existing=$(docker image inspect -f '{{index .Config.Labels "final-project.controller-source"}}' final-project-controller:local 2>/dev/null || true)
if [[ "$existing" != "$fingerprint" ]]; then
  case "$(uname -m)" in x86_64) target_arch=amd64;; aarch64) target_arch=arm64;; esac
  docker build --load --platform "linux/$target_arch" --build-arg "TARGETARCH=$target_arch" --label "final-project.controller-source=$fingerprint" -t final-project-controller:local ./controller
fi
# Docker may run via sudo while the invoking project user stays unprivileged.
owner_uid=$UID
owner_gid=$(id -g)
if (( EUID == 0 )) && [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  owner_uid=$SUDO_UID
  owner_gid=$SUDO_GID
fi
settings_args=()
for key in "${PROJECT_SETTINGS[@]}"; do settings_args+=(-e "$key=${!key}"); done
# Only project state is mounted; the host's ~/.kube is never used.
docker run --rm --network host \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  -e KUBECONFIG=/project/.state/kubeconfig \
  -e "FINAL_PROJECT_HOST_UID=$owner_uid" -e "FINAL_PROJECT_HOST_GID=$owner_gid" \
  -v "$DOCKER_SOCKET:/var/run/docker.sock" \
  "${settings_args[@]}" \
  -v "$ROOT:/project" -w /project \
  --entrypoint /bin/bash final-project-controller:local \
  /project/scripts/controller-entry.sh "$@"
