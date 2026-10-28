#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/scripts/common.sh"
check_host
check_compose_ownership
# A single controller call refreshes credentials and runs the complete check.
./scripts/control.sh bash scripts/check-status.sh
