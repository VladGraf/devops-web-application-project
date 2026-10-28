#!/usr/bin/env bash
# Shared host checks. Sourcing this file does not start any services.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/config.sh" || return 1
source "$ROOT/scripts/checks.sh" || return 1
if [[ "${FINAL_PROJECT_SUDO_DOCKER:-0}" == 1 ]]; then
  docker() {
    if [[ "${FINAL_PROJECT_SUDO_NONINTERACTIVE:-0}" == 1 ]]; then
      sudo -n -- docker --host "${FINAL_PROJECT_DOCKER_ENDPOINT:?}" "$@"
    else sudo -- docker --host "${FINAL_PROJECT_DOCKER_ENDPOINT:?}" "$@"; fi
  }
fi
compose() { docker compose --project-name final-project --env-file /dev/null -f "$ROOT/infra/docker-compose.yml" "$@"; }
fail() { echo "ERROR: $*" >&2; return 1; }
version_at_least() { [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
check_host() {
  echo '[preflight] Checking Docker versions, access and permissions.' >&2
  [[ "$(uname -s)" == Linux ]] || { fail 'Use a native Linux host; see README.md'; return 1; }
  local tool version endpoint security os_id os_version
  for tool in docker awk df sort head sha256sum mktemp getconf grep cut cat dirname mkdir chmod mv rmdir uname timeout; do
    command -v "$tool" >/dev/null || { fail "Missing host command: $tool. See README.md"; return 1; }
  done
  os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
  os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
  case "$os_id:$os_version" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) fail "Supported systems are Debian 12/13 and Ubuntu 22.04/24.04; found $os_id $os_version"; return 1;;
  esac
  docker_check info >/dev/null || { fail 'Docker is not running, or your user cannot access it. Check docker info and Docker permissions'; return 1; }
  version=$(docker_check version --format '{{.Server.Version}}')
  version_at_least "$version" 27.5.1 || { fail "Docker Engine 27.5.1 or newer is required; found $version"; return 1; }
  version=$(docker_check compose version --short) || { fail 'Docker Compose plugin 2.24.0 or newer is required'; return 1; }
  docker_check buildx version >/dev/null || { fail 'Docker Buildx plugin is required to build the project images. Install the standard Docker build plugins'; return 1; }
  version=${version#v}
  version_at_least "$version" 2.24.0 || { fail "Compose 2.24.0 or newer is required; found $version"; return 1; }
  case "$(uname -m)" in x86_64|aarch64) ;; *) fail 'Supported CPUs: x86_64 and aarch64'; return 1;; esac
  [[ "$(docker_check info --format '{{.OSType}}')" == linux ]] || { fail 'Docker must run Linux containers'; return 1; }
  security=$(docker_check info --format '{{json .SecurityOptions}}')
  [[ "$security" != *rootless* && "$security" != *userns* ]] || { fail 'Use rootful Docker without user namespace remapping for nested k3d'; return 1; }
  [[ "$(docker_check info --format '{{.CgroupVersion}}')" == 2 ]] || { fail 'This project requires cgroup v2'; return 1; }
  if [[ "${FINAL_PROJECT_SUDO_DOCKER:-0}" == 1 ]]; then
    endpoint=${FINAL_PROJECT_DOCKER_ENDPOINT:?}
  elif [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    endpoint=$(docker_check context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
  else
    endpoint=${DOCKER_HOST:-}
    if [[ -z "$endpoint" ]]; then endpoint=$(docker_check context inspect --format '{{.Endpoints.docker.Host}}'); fi
  fi
  [[ "$(docker_check info --format '{{.OperatingSystem}}')" != *'Docker Desktop'* ]] || { fail 'Docker Desktop is unsupported; use native Docker Engine'; return 1; }
  [[ "$endpoint" == unix://* ]] || { fail 'Use a local Docker Engine with a Unix socket; remote Docker is unsupported'; return 1; }
  DOCKER_SOCKET=${endpoint#unix://}
  [[ -S "$DOCKER_SOCKET" ]] && { [[ -r "$DOCKER_SOCKET" && -w "$DOCKER_SOCKET" ]] || [[ "${FINAL_PROJECT_SUDO_DOCKER:-0}" == 1 ]]; } || { fail "Docker socket is not accessible: $DOCKER_SOCKET"; return 1; }
  [[ "$ROOT" != *:* && "$DOCKER_SOCKET" != *:* ]] || { fail 'Project and socket paths must not contain a colon'; return 1; }
  [[ -w "$ROOT" && -x "$ROOT" ]] || { fail 'The project directory must be writable by your user'; return 1; }
  if [[ -e "$ROOT/.state" && ( ! -d "$ROOT/.state" || ! -w "$ROOT/.state" || ! -x "$ROOT/.state" ) ]]; then
    fail 'Project .state must be a writable directory'; return 1
  fi
}
check_compose_ownership() {
  local service owner actual result
  for service in nginx elasticsearch logstash kibana; do
    if docker_check container inspect "final-project-$service" >/dev/null 2>&1; then
      owner=$(docker_check inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "final-project-$service") || return "$?"
      actual=$(docker_check inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "final-project-$service") || return "$?"
      [[ "$owner" == final-project && "$actual" == "$service" ]] || {
        echo "Refusing to change unrelated container final-project-$service" >&2; return 1;
      }
    else
      result=$?
      if check_timed_out "$result"; then fail 'Docker ownership inspection timed out'; return "$result"; fi
    fi
  done
  for service in k3d-final-project-server-0 k3d-final-project-agent-0 k3d-final-project-agent-1 k3d-final-project-serverlb; do
    if docker_check container inspect "$service" >/dev/null 2>&1; then
      owner=$(docker_check inspect -f '{{index .Config.Labels "k3d.cluster"}}' "$service") || return "$?"
      [[ "$owner" == final-project ]] || {
        echo "Refusing to change unrelated container $service" >&2; return 1;
      }
    else
      result=$?
      if check_timed_out "$result"; then fail 'Docker ownership inspection timed out'; return "$result"; fi
    fi
  done
  if docker_check network inspect final-project_default >/dev/null 2>&1; then
    owner=$(docker_check network inspect -f '{{index .Labels "com.docker.compose.project"}}' final-project_default) || return "$?"
    [[ "$owner" == final-project ]] || { echo 'Network name belongs to another project' >&2; return 1; }
  else
    result=$?
    if check_timed_out "$result"; then fail 'Docker network inspection timed out'; return "$result"; fi
  fi
  if docker_check volume inspect final-project_esdata >/dev/null 2>&1; then
    owner=$(docker_check volume inspect -f '{{index .Labels "com.docker.compose.project"}}' final-project_esdata) || return "$?"
    [[ "$owner" == final-project ]] || { echo 'Volume name belongs to another project' >&2; return 1; }
  else
    result=$?
    if check_timed_out "$result"; then fail 'Docker volume inspection timed out'; return "$result"; fi
  fi
}
lock_project() {
  mkdir -p "$ROOT/.state"
  chmod 700 "$ROOT/.state"
  if ! mkdir "$ROOT/.state/operation.lock" 2>/dev/null; then
    echo 'Another project operation is running. See docs/TROUBLESHOOTING.md.' >&2
    return 1
  fi
  trap 'rmdir "$ROOT/.state/operation.lock"' EXIT
}
