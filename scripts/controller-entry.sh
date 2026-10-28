#!/usr/bin/env bash
set -euo pipefail
# Commands that start/stop a cluster must work while its nodes are stopped.
# Ansible refreshes credentials itself after cluster creation.
case "${1:-} ${2:-}" in
  'kubectl '*|'bash scripts/release.sh'|'bash scripts/check-status.sh')
    bash scripts/cluster.sh refresh
    ;;
esac
exec "$@"
