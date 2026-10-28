#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
check_only=0
assume_yes=0
for argument in "$@"; do
  case "$argument" in
    --check) check_only=1;;
    --yes) assume_yes=1;;
    --help|-h)
      echo 'Usage: ./deploy.sh [--check] [--yes]'
      echo '--check: inspect requirements only; never install or deploy.'
      echo '--yes: approve the displayed host actions without prompting; needs root or non-interactive sudo.'
      exit 0;;
    *) echo "Unknown option: $argument. Use --help." >&2; exit 2;;
  esac
done
if (( check_only )); then
  # Check mode must not inherit privileged Docker behavior from another run.
  unset FINAL_PROJECT_SUDO_DOCKER FINAL_PROJECT_DOCKER_ENDPOINT FINAL_PROJECT_SUDO_NONINTERACTIVE
fi
if (( check_only )); then
  source "$PROJECT_ROOT/scripts/installer.sh"
  installer_main 1 "$assume_yes"
  echo 'Check complete. No host or project state was changed; no deployment started.'
  exit 0
fi
source "$PROJECT_ROOT/scripts/logging.sh"
run_deployment_logged "$PROJECT_ROOT" "$assume_yes"
