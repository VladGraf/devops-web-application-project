#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
check_host
check_compose_ownership
lock_project
./scripts/control.sh bash scripts/release.sh update
