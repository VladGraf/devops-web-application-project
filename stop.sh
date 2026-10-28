#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
check_host
check_compose_ownership
lock_project
./scripts/control.sh bash scripts/cluster.sh verify
./scripts/control.sh k3d cluster stop final-project
compose stop
echo 'Project stopped; data is kept.'
