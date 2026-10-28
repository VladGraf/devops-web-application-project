#!/usr/bin/env bash
# Sourcing this file only defines functions. Host changes require explicit consent.
source "${BASH_SOURCE[0]%/*}/checks.sh" || return 1
installer_error() { echo "Installer error: $*" >&2; return 1; }
installer_os() {
  local file=${1:-/etc/os-release} key value
  HOST_ID=''; HOST_VERSION=''; HOST_SUITE=''
  [[ -r "$file" ]] || { installer_error "Cannot read $file"; return 1; }
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value=${value%$'\r'}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    case "$key" in ID) HOST_ID=$value;; VERSION_ID) HOST_VERSION=$value;; esac
  done < "$file"
  case "$HOST_ID:$HOST_VERSION" in
    debian:12) HOST_SUITE=bookworm;; debian:13) HOST_SUITE=trixie;;
    ubuntu:22.04) HOST_SUITE=jammy;; ubuntu:24.04) HOST_SUITE=noble;;
    *) installer_error "Unsupported operating system: ${HOST_ID:-unknown} ${HOST_VERSION:-unknown}. Use Debian 12/13 or Ubuntu 22.04/24.04 LTS"; return 1;;
  esac
  [[ "$(uname -s)" == Linux ]] || { installer_error 'A native Linux host is required'; return 1; }
  case "$(uname -m)" in x86_64) HOST_ARCH=amd64;; aarch64) HOST_ARCH=arm64;;
    *) installer_error 'Supported architectures: x86_64 and ARM64'; return 1;; esac
  command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || {
    installer_error 'This installer requires the Debian/Ubuntu APT package manager'; return 1;
  }
}
installer_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == 'install ok installed' ]]; }
installer_add_package() {
  local present
  for present in "${INSTALL_PACKAGES[@]}"; do [[ "$present" == "$1" ]] && return 0; done
  INSTALL_PACKAGES+=("$1")
}
installer_minimum() {
  local actual=$1 minimum=$2 a_major a_minor a_patch b_major b_minor b_patch
  [[ "$actual" =~ ^([0-9]{1,5})[.]([0-9]{1,5})[.]([0-9]{1,5}) ]] || return 1
  a_major=$((10#${BASH_REMATCH[1]})); a_minor=$((10#${BASH_REMATCH[2]})); a_patch=$((10#${BASH_REMATCH[3]}))
  [[ "$minimum" =~ ^([0-9]{1,5})[.]([0-9]{1,5})[.]([0-9]{1,5}) ]] || return 1
  b_major=$((10#${BASH_REMATCH[1]})); b_minor=$((10#${BASH_REMATCH[2]})); b_patch=$((10#${BASH_REMATCH[3]}))
  (( a_major > b_major || (a_major == b_major && a_minor > b_minor) ||
     (a_major == b_major && a_minor == b_minor && a_patch >= b_patch) ))
}
installer_endpoint() {
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    INSTALL_DOCKER_ENDPOINT=$(docker_check context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}') || return 1
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    INSTALL_DOCKER_ENDPOINT=$DOCKER_HOST
  elif command -v docker >/dev/null; then
    INSTALL_DOCKER_ENDPOINT=$(docker_check context inspect --format '{{.Endpoints.docker.Host}}') || return 1
  else
    INSTALL_DOCKER_ENDPOINT=unix:///var/run/docker.sock
  fi
  [[ "$INSTALL_DOCKER_ENDPOINT" == unix://* ]] || { installer_error 'Remote Docker is unsupported; select a local Unix socket'; return 1; }
}
installer_validate_daemon() {
  local security
  [[ "$(docker_check info --format '{{.OSType}}')" == linux ]] || { installer_error 'Docker must run Linux containers'; return 1; }
  [[ "$(docker_check info --format '{{.OperatingSystem}}')" != *'Docker Desktop'* ]] || { installer_error 'Use native Docker Engine, not Docker Desktop'; return 1; }
  security=$(docker_check info --format '{{json .SecurityOptions}}') || return 1
  [[ "$security" != *rootless* && "$security" != *userns* ]] || {
    installer_error 'Use rootful Docker without user namespace remapping; existing daemon settings were not changed'; return 1;
  }
  [[ "$(docker_check info --format '{{.CgroupVersion}}')" == 2 ]] || { installer_error 'Docker requires cgroup v2 for this project'; return 1; }
}
installer_environment() {
  [[ -r /sys/fs/cgroup/cgroup.controllers ]] || { installer_error 'Enable cgroup v2 before using this project; boot settings are never changed automatically'; return 1; }
  [[ -w "$PROJECT_ROOT" && -x "$PROJECT_ROOT" ]] || { installer_error 'The downloaded project directory must be writable'; return 1; }
}
installer_plan() {
  INSTALL_PACKAGES=(); INSTALL_NEW_ENGINE=0; INSTALL_SUDO_DOCKER=0; INSTALL_SYSCTL=0
  INSTALL_DOCKER_REPO=0; INSTALL_BASE_MISSING=0
  local tool package version conflict result
  for tool in awk df getconf grep sort sha256sum mktemp curl sysctl head cut cat dirname mkdir chmod mv rmdir uname install tee timeout; do
    if ! command -v "$tool" >/dev/null; then
      case "$tool" in awk) package=gawk;; getconf) package=libc-bin;; grep) package=grep;;
        curl) package=curl;; sysctl) package=procps;; *) package=coreutils;; esac
      installer_add_package "$package"
      [[ "$tool" == curl || "$tool" == sysctl ]] || INSTALL_BASE_MISSING=1
    fi
  done
  installer_installed ca-certificates || installer_add_package ca-certificates
  if command -v docker >/dev/null; then
    installer_endpoint || return 1
    if docker_check info >/dev/null; then
      version=$(docker_check version --format '{{.Server.Version}}') || return 1
      installer_minimum "$version" 27.5.1 || {
        installer_error "Existing Docker $version is too old. Upgrade it separately; this installer never replaces an existing engine"; return 1;
      }
    else
      result=$?
      if check_timed_out "$result"; then return "$result"; fi
      if installer_installed docker-ce-cli && ! installer_installed docker-ce && ! installer_installed docker.io && ! command -v dockerd >/dev/null; then
        # A managed CLI without an Engine is different from a stopped daemon.
        INSTALL_NEW_ENGINE=1; INSTALL_DOCKER_REPO=1
        installer_add_package docker-ce
        installer_add_package containerd.io
      else INSTALL_SUDO_DOCKER=1; fi
    fi
    if version=$(docker_check compose version --short); then
      installer_minimum "${version#v}" 2.24.0 || {
        installer_error 'Existing Compose is too old. Update it separately; it will not be replaced automatically'; return 1;
      }
    else
      result=$?
      if check_timed_out "$result"; then return "$result"; fi
      installer_add_package docker-compose-plugin
      INSTALL_DOCKER_REPO=1
    fi
    if docker_check buildx version >/dev/null; then :;
    else
      result=$?
      if check_timed_out "$result"; then return "$result"; fi
      installer_add_package docker-buildx-plugin
      INSTALL_DOCKER_REPO=1
    fi
    if (( INSTALL_DOCKER_REPO )) && ! installer_installed docker-ce-cli; then
      installer_error 'The working Docker CLI is not managed by Docker CE packages. Install compatible plugins separately; this installer will not replace your Docker installation'; return 1
    fi
  else
    # Do not repair or start an unknown existing runtime behind the user's back.
    for conflict in docker-ce docker-ce-cli docker.io podman-docker containerd.io containerd runc; do
      if installer_installed "$conflict"; then
        installer_error "Existing runtime package $conflict needs attention. It will not be replaced or restarted"; return 1
      fi
    done
    if command -v dockerd >/dev/null || command -v containerd >/dev/null; then
      installer_error 'An unmanaged runtime binary already exists. It will not be overwritten'; return 1
    fi
    INSTALL_NEW_ENGINE=1; INSTALL_DOCKER_REPO=1
    installer_endpoint || return 1
    for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do installer_add_package "$package"; done
  fi
  if (( INSTALL_DOCKER_REPO )); then
    for conflict in docker.io docker-compose docker-compose-v2 docker-buildx docker-doc podman-docker containerd runc; do
      if installer_installed "$conflict"; then
        installer_error "Conflicting package $conflict is installed. Resolve it separately; automatic removal is disabled"; return 1
      fi
    done
  fi
  [[ -r /proc/sys/vm/max_map_count ]] || { installer_error 'Cannot read vm.max_map_count'; return 1; }
  read -r version < /proc/sys/vm/max_map_count
  (( version >= 262144 )) || INSTALL_SYSCTL=1
}
installer_show_plan() {
  echo "Host: $HOST_ID $HOST_VERSION ($HOST_ARCH)"
  if (( ${#INSTALL_PACKAGES[@]} )); then
    printf 'Install missing packages with APT: %s\n' "${INSTALL_PACKAGES[*]}"
  fi
  (( INSTALL_DOCKER_REPO == 0 )) || echo "Use Docker's signed official $HOST_ID/$HOST_SUITE repository."
  (( INSTALL_NEW_ENGINE == 0 )) || echo 'Install and start a new Docker Engine only if no old runtime or Docker data is present.'
  (( INSTALL_SUDO_DOCKER == 0 && INSTALL_NEW_ENGINE == 0 )) || echo 'Use sudo for Docker commands if needed; do not change user groups or socket permissions.'
  (( INSTALL_SYSCTL == 0 )) || echo 'Set vm.max_map_count=262144 and save /etc/sysctl.d/99-final-project.conf.'
  echo 'Existing working software is kept. No package removal, runtime replacement, or unrelated container changes are allowed.'
}
installer_confirm() {
  local answer result seconds=${FINAL_PROJECT_CONFIRM_TIMEOUT_SECONDS:-120}
  if (( ${INSTALL_ASSUME_YES:-0} )); then return 0; fi
  [[ -t 0 ]] || { installer_error 'Host changes need confirmation. Run interactively or pass --yes after reviewing --check'; return 1; }
  [[ "$seconds" =~ ^[1-9][0-9]{0,2}$ ]] && (( seconds <= 600 )) || {
    installer_error 'Confirmation timeout must be 1 to 600 seconds'; return 1;
  }
  printf 'Approve the host actions listed above? [y/N] (timeout: %ss; default: cancel)\n' "$seconds"
  if read -r -t "$seconds" answer; then :;
  else
    result=$?
    if (( result > 128 )); then
      installer_error "Confirmation timed out after $seconds seconds; installation cancelled, no approval assumed"
    else installer_error 'Confirmation input closed; installation cancelled'; fi
    return 1
  fi
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || { installer_error 'Installation cancelled; no host changes made'; return 1; }
}
installer_root() {
  if (( EUID == 0 )); then "$@";
  elif (( ${INSTALL_ASSUME_YES:-0} )); then sudo -n -- "$@";
  else sudo -- "$@"; fi
}
installer_authenticate() {
  if (( EUID != 0 )); then
    command -v sudo >/dev/null || { installer_error 'sudo is required for approved host changes. Ask an administrator to install it, or run as root'; return 1; }
    if (( INSTALL_ASSUME_YES )); then
      sudo -n -v || { installer_error '--yes requires root, passwordless sudo, or a valid sudo session'; return 1; }
    else sudo -v || { installer_error 'Administrator authentication failed'; return 1; }; fi
  fi
}
installer_enable_docker_access() {
  local result
  if docker_check info >/dev/null; then return 0;
  else result=$?; fi
  if check_timed_out "$result"; then return "$result"; fi
  if FINAL_PROJECT_SUDO_DOCKER=1 FINAL_PROJECT_DOCKER_ENDPOINT="$INSTALL_DOCKER_ENDPOINT" docker_check info >/dev/null; then :;
  else
    result=$?
    if check_timed_out "$result"; then return "$result"; fi
    installer_error 'Docker is installed but unavailable, stopped, or misconfigured. Existing daemons are not restarted; fix Docker and rerun'; return 1
  fi
  export FINAL_PROJECT_SUDO_DOCKER=1
  export FINAL_PROJECT_DOCKER_ENDPOINT=$INSTALL_DOCKER_ENDPOINT
  export FINAL_PROJECT_SUDO_NONINTERACTIVE=${INSTALL_ASSUME_YES:-0}
  # Only this process and its project children gain the approved wrapper.
  docker() {
    if [[ "${FINAL_PROJECT_SUDO_NONINTERACTIVE:-0}" == 1 ]]; then
      sudo -n -- docker --host "$FINAL_PROJECT_DOCKER_ENDPOINT" "$@"
    else sudo -- docker --host "$FINAL_PROJECT_DOCKER_ENDPOINT" "$@"; fi
  }
}
installer_safe_apt() {
  local simulation
  # Simulate the exact install first. Never remove or upgrade installed packages.
  simulation=$(installer_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 --simulate --no-remove --no-upgrade --no-install-recommends install "$@") || {
    installer_error 'APT cannot safely satisfy these packages. No automatic removals or upgrades are allowed'; return 1;
  }
  if grep -Eq '^(Remv |Inst [^ ]+ \[)' <<< "$simulation"; then
    installer_error 'APT proposed removing or upgrading existing packages. Installation stopped'; return 1
  fi
  installer_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 --yes --no-remove --no-upgrade --no-install-recommends install "$@"
}
installer_repository() (
  set -euo pipefail
  local source=/etc/apt/sources.list.d/final-project-docker.sources key=/etc/apt/keyrings/final-project-docker.asc temp policy entry
  temp=$(mktemp -d) || return 1
  trap 'rm -rf "$temp"' EXIT
  printf '# final-project managed Docker repository\nTypes: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
    "$HOST_ID" "$HOST_SUITE" "$HOST_ARCH" "$key" > "$temp/docker.sources" || return 1
  if [[ -L "$source" || -L "$key" ]] ||
     { [[ -e "$source" ]] && ! cmp -s "$source" "$temp/docker.sources"; }; then
    installer_error 'Project Docker repository files conflict with the expected configuration; nothing was overwritten'; return 1
  fi
  # Reuse an existing configured official repository without changing it.
  policy=$(apt-cache policy docker-ce) || return 1
  if [[ ! -e "$source" && ! -e "$key" ]] && grep -Fq "https://download.docker.com/linux/$HOST_ID" <<< "$policy"; then
    return 0
  fi
  # Avoid duplicate source entries with a different Signed-By key.
  while IFS= read -r entry; do
    [[ "$entry" == "$source" ]] || {
      installer_error 'An existing Docker repository needs repair. It is left unchanged'; return 1;
    }
  done < <(grep -RlFs "download.docker.com/linux/$HOST_ID" /etc/apt/sources.list /etc/apt/sources.list.d || true)
  echo '[installer] Downloading Docker signing key (10s connect, 60s total).' >&2
  curl --connect-timeout 10 --max-time 60 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://download.docker.com/linux/$HOST_ID/gpg" -o "$temp/docker.asc" || return 1
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$temp/docker.asc" || { installer_error 'Invalid Docker signing key'; return 1; }
  if [[ -e "$key" ]] && ! cmp -s "$key" "$temp/docker.asc"; then
    installer_error 'Existing project Docker signing key differs from the official key; nothing was overwritten'; return 1
  fi
  installer_root install -d -m 0755 /etc/apt/keyrings || return 1
  if [[ ! -e "$key" ]]; then installer_root install -m 0644 "$temp/docker.asc" "$key" || return 1; fi
  if [[ ! -e "$source" ]]; then installer_root install -m 0644 "$temp/docker.sources" "$source" || return 1; fi
)
installer_new_engine_guard() {
  local directory
  for directory in /var/lib/docker /var/lib/containerd; do
    if installer_root test -e "$directory"; then
      # Even unreadable or empty old stores need a separate recovery decision.
      installer_error "Existing runtime data path $directory found. No engine installation will be attempted"; return 1
    fi
  done
  if installer_root test -S "${INSTALL_DOCKER_ENDPOINT#unix://}" || installer_root test -S /run/containerd/containerd.sock; then
    installer_error 'An existing runtime socket was found. No new engine will be installed'; return 1
  fi
  local config
  for config in /etc/systemd/system/docker.service /etc/systemd/system/docker.service.d /etc/systemd/system/containerd.service /etc/systemd/system/containerd.service.d; do
    if installer_root test -e "$config"; then
      installer_error "Existing runtime service configuration $config was left unchanged"; return 1
    fi
  done
  if installer_root test -e /etc/docker/daemon.json; then
    installer_error 'Existing Docker daemon configuration found. Review it before installing a new engine'; return 1
  fi
  [[ -d /run/systemd/system ]] || { installer_error 'A native Linux system running systemd is required for a new Docker service'; return 1; }
}
installer_kernel() {
  local file=/etc/sysctl.d/99-final-project.conf contents
  contents=$'# final-project managed kernel setting\nvm.max_map_count=262144'
  if [[ -e "$file" ]] && ! grep -qx '# final-project managed kernel setting' "$file"; then
    installer_error "$file is not owned by this installer; it was left unchanged"; return 1
  fi
  printf '%s\n' "$contents" | installer_root tee "$file" >/dev/null || return 1
  installer_root sysctl -w vm.max_map_count=262144
}
installer_apply() {
  local package
  installer_confirm || return 1
  echo '[installer] Approval received; checking administrator access.' >&2
  installer_authenticate || return 1
  if (( INSTALL_NEW_ENGINE )); then installer_new_engine_guard || return 1;
  elif (( INSTALL_SUDO_DOCKER )); then
    installer_enable_docker_access || return 1
    installer_validate_daemon || return 1
    local accessible_version
    accessible_version=$(docker_check version --format '{{.Server.Version}}') || return 1
    installer_minimum "$accessible_version" 27.5.1 || { installer_error 'Existing Docker is too old; no packages were installed'; return 1; }
  fi
  if (( ${#INSTALL_PACKAGES[@]} )); then
    installer_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 update || {
      installer_error 'APT update failed. Check Internet access and configured repositories'; return 1;
    }
    local base=() docker_packages=()
    for package in "${INSTALL_PACKAGES[@]}"; do
      case "$package" in docker-*|containerd.io) docker_packages+=("$package");; *) base+=("$package");; esac
    done
    if (( ${#base[@]} )); then installer_safe_apt "${base[@]}" || return 1; fi
    if (( ${#docker_packages[@]} )); then
      installer_repository || return 1
      installer_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 update || return 1
      installer_safe_apt "${docker_packages[@]}" || return 1
    fi
  fi
  if (( INSTALL_NEW_ENGINE )); then
    installer_root systemctl start docker || { installer_error 'The newly installed Docker daemon could not start'; return 1; }
    installer_enable_docker_access || return 1
  fi
  (( INSTALL_SYSCTL == 0 )) || installer_kernel || return 1
}
installer_main() {
  local check_only=$1 result
  echo '[installer] Detecting OS and architecture.' >&2
  INSTALL_ASSUME_YES=$2
  installer_os || return 1
  installer_environment || return 1
  echo '[installer] Checking dependencies and Docker access (bounded checks).' >&2
  installer_plan || return 1
  installer_show_plan
  if command -v docker >/dev/null && docker_check info >/dev/null; then
    installer_validate_daemon || return 1
  else
    result=$?
    if check_timed_out "$result"; then return "$result"; fi
  fi
  # Core tools are normally part of a base Debian/Ubuntu install. Do not use
  # the configuration loader until its required commands are available.
  if (( INSTALL_BASE_MISSING == 0 )); then
    source "$PROJECT_ROOT/scripts/common.sh" || return 1
    source "$ROOT/scripts/preflight.sh" || return 1
    echo '[installer] Checking CPU, RAM and disk space.' >&2
    if (( INSTALL_NEW_ENGINE )); then check_resources bootstrap-fresh || return 1;
    else check_resources bootstrap || return 1; fi
    echo '[installer] Checking required ports.' >&2
    if (( INSTALL_SUDO_DOCKER == 0 )); then check_ports || return 1;
    else echo 'Docker ownership/port checks need approved daemon access; pending.'; fi
  else echo 'Resource/configuration checks are pending installation of missing base commands.'; fi
  if (( ${#INSTALL_PACKAGES[@]} || INSTALL_SUDO_DOCKER || INSTALL_SYSCTL )); then
    if (( check_only )); then echo 'Requirements are not ready. Check mode made no changes.'; return 1; fi
    installer_apply || return 1
  fi
  source "$PROJECT_ROOT/scripts/common.sh" || return 1
  source "$ROOT/scripts/preflight.sh" || return 1
  echo '[installer] Running final host checks.' >&2
  preflight || return 1
  echo 'Host requirements passed.'
}
