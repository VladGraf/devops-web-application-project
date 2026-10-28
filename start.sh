#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
source "$ROOT/scripts/preflight.sh"
preflight
lock_project
./scripts/control.sh bash scripts/cluster.sh verify
save_config
compose up -d --wait --wait-timeout 420
./scripts/control.sh k3d cluster start final-project --wait --timeout 240s
# Reconcile the Logstash endpoint and configuration after a restart.
./scripts/control.sh ansible-playbook -i localhost, ansible/deploy.yml
./status.sh
