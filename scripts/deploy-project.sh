#!/usr/bin/env bash
# Deployment body. The public entry point adds redacted, persistent logging.
set -Eeuo pipefail
PROJECT_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
assume_yes=${1:?Expected installation approval mode}
stage=initialization
trap 'result=$?; printf "\n[stage=%s] FAILED exit_code=%d\n" "$stage" "$result" >&2' ERR
source "$PROJECT_ROOT/scripts/installer.sh"
stage=installer
printf '\n[stage=%s] started\n' "$stage"
installer_main 0 "$assume_yes"
printf '[stage=%s] exit_code=0\n' "$stage"
lock_project
stage=cluster-validation
printf '\n[stage=%s] started\n' "$stage"
existing_cluster=0
# Validate an existing project cluster before changing any infrastructure.
if docker ps -a --filter label=k3d.cluster=final-project --format '{{.Names}}' | grep -q .; then
  ./scripts/control.sh bash scripts/cluster.sh verify
  existing_cluster=1
fi
printf '[stage=%s] exit_code=0\n' "$stage"
save_config
stage=docker-services
printf '\n[stage=%s] started\n' "$stage"
echo 'Starting project Nginx and ELK...'
compose up -d --wait --wait-timeout 420
printf '[stage=%s] exit_code=0\n' "$stage"
stage=cluster-start
printf '\n[stage=%s] started\n' "$stage"
if (( existing_cluster == 1 )); then
  ./scripts/control.sh k3d cluster start final-project --wait --timeout 240s
fi
printf '[stage=%s] exit_code=0\n' "$stage"
stage=ansible
printf '\n[stage=%s] started\n' "$stage"
echo 'Checking K3s and deploying with Ansible...'
./scripts/control.sh env ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 \
  ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_DISPLAY_ARGS_TO_STDOUT=false \
  ansible-playbook --verbose -i localhost, ansible/deploy.yml
printf '[stage=%s] exit_code=0\n' "$stage"
stage=status
printf '\n[stage=%s] started\n' "$stage"
./status.sh
printf '[stage=%s] exit_code=0\n' "$stage"
echo "Done. Web: http://localhost:$WEB_PORT | Kibana: http://localhost:$KIBANA_PORT"
