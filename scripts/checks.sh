#!/usr/bin/env bash
# Bound read-only Docker clients, never daemon processes or container workloads.
check_timed_out() { [[ "$1" == 124 || "$1" == 137 ]]; }
docker_check() {
  local seconds=${FINAL_PROJECT_DOCKER_CHECK_TIMEOUT_SECONDS:-30} result
  local -a client=(docker)
  [[ "$seconds" =~ ^[1-9][0-9]{0,2}$ ]] && (( seconds <= 120 )) || {
    echo 'ERROR: Docker check timeout must be 1 to 120 seconds.' >&2; return 2;
  }
  command -v timeout >/dev/null || { echo 'ERROR: coreutils timeout is required for Docker checks.' >&2; return 127; }
  if [[ "${FINAL_PROJECT_SUDO_DOCKER:-0}" == 1 ]]; then
    client+=(--host "${FINAL_PROJECT_DOCKER_ENDPOINT:?}")
    # Checks must never stop at another invisible sudo prompt.
    if (( EUID != 0 )); then client=(sudo -n -- "${client[@]}"); fi
  fi
  if timeout --kill-after=5s "${seconds}s" "${client[@]}" "$@"; then return 0;
  else result=$?; fi
  if check_timed_out "$result"; then
    printf 'ERROR: Docker %s check timed out after %s seconds (exit_code=%s).\n' "${1:-API}" "$seconds" "$result" >&2
  fi
  return "$result"
}
