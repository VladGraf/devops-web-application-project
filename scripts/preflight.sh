#!/usr/bin/env bash
# Deployment-only checks; no container, cluster or host setting is changed.
port_is_listening() {
  local hex
  local files=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && files+=(/proc/net/tcp6)
  printf -v hex '%04X' "$1"
  awk -v port="$hex" '$4 == "0A" {split($2, a, ":"); if (a[2] == port) found=1} END {exit !found}' "${files[@]}"
}
port_is_project_owned() {
  local container=$1 port=$2 actual owner
  actual=$(docker_check inspect -f '{{if .State.Running}}{{range .HostConfig.PortBindings}}{{range .}}{{println .HostPort}}{{end}}{{end}}{{end}}' "$container" 2>/dev/null) || return "$?"
  [[ $'\n'"$actual"$'\n' == *$'\n'"$port"$'\n'* ]] || return 1
  if [[ "${3:-}" == NODE_PORT ]]; then
    owner=$(docker_check inspect -f '{{index .Config.Labels "k3d.cluster"}}' "$container" 2>/dev/null) || return "$?"
    [[ "$owner" == final-project ]] || return 1
  fi
}
check_ports() {
  local key container port result
  [[ -r /proc/net/tcp ]] || { fail 'Cannot inspect listening TCP ports through /proc/net/tcp'; return 1; }
  for key in WEB_PORT KIBANA_PORT NODE_PORT ES_PORT API_PORT; do
    port=${!key}
    case "$key" in
      WEB_PORT) container=final-project-nginx;;
      KIBANA_PORT) container=final-project-kibana;;
      NODE_PORT) container=k3d-final-project-serverlb;;
      ES_PORT) container=final-project-elasticsearch;;
      API_PORT) container=k3d-final-project-serverlb;;
    esac
    if port_is_listening "$port"; then
      if port_is_project_owned "$container" "$port" "$key"; then :;
      else
        result=$?
        if check_timed_out "$result"; then fail 'Docker port ownership inspection timed out'; return "$result"; fi
        fail "$key=$port is already in use. Choose another value in .env or your environment"; return 1
      fi
    fi
    # Docker can reserve a published port even when it is absent from /proc/net.
    local published name
    published=''
    if command -v docker >/dev/null; then published=$(docker_check ps --format '{{.Names}}') || return 1; fi
    while IFS= read -r name; do
      [[ -z "$name" || "$name" == "$container" ]] && continue
      if port_is_project_owned "$name" "$port"; then
        fail "$key=$port is reserved by another container: $name"; return 1
      else
        result=$?
        if check_timed_out "$result"; then fail 'Docker published-port inspection timed out'; return "$result"; fi
      fi
    done <<< "$published"
  done
}
check_resources() {
  local total available disk_free cpus budget existing
  total=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  available=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  cpus=$(getconf _NPROCESSORS_ONLN)
  (( cpus >= 4 )) || { fail 'At least 4 logical CPUs are required'; return 1; }
  (( APP_CPU_REQUEST_MILLICORES * 3 + FLUENT_CPU_REQUEST_MILLICORES * 3 + 500 <= cpus * 1000 )) || {
    fail 'Configured Pod CPU requests exceed host CPU capacity after K3s overhead'; return 1;
  }
  budget=$(( SERVER_MEMORY_MB + 2 * WORKER_MEMORY_MB + NGINX_MEMORY_MB + ES_MEMORY_MB + LOGSTASH_MEMORY_MB + KIBANA_MEMORY_MB + 1024 ))
  (( budget < 10240 )) && budget=10240
  (( total >= budget + 2048 )) || { fail "Need at least $((budget+2048)) MiB total RAM for these limits; found $total MiB"; return 1; }
  existing=''
  local docker_ready=0
  if command -v docker >/dev/null && docker_check info >/dev/null; then
    docker_ready=1
    existing=$(docker_check ps --filter label=com.docker.compose.project=final-project --format '{{.Names}}') || return "$?"
    existing+=$(docker_check ps --filter label=k3d.cluster=final-project --format '{{.Names}}') || return "$?"
  else
    local result=$?
    if check_timed_out "$result"; then return "$result"; fi
    if [[ "${1:-}" == bootstrap ]] && command -v docker >/dev/null; then existing='access-pending'; fi
  fi
  if [[ -z "$existing" ]]; then
    (( available >= budget )) || { fail "Need $budget MiB available RAM for first startup; found $available MiB"; return 1; }
  else
    (( available >= 2048 )) || { fail "Need at least 2048 MiB available RAM while the project is running; found $available MiB"; return 1; }
  fi
  disk_free=$(df -Pm "$ROOT" | awk 'END {print $4}')
  (( disk_free >= 25600 )) || { fail "Need 25 GiB free in the project filesystem; found $disk_free MiB"; return 1; }
  local docker_root
  docker_root=/var/lib
  if (( docker_ready )); then docker_root=$(docker_check info --format '{{.DockerRootDir}}') || return "$?"; fi
  [[ -d "$docker_root" ]] || { fail 'Cannot locate the local Docker data filesystem'; return 1; }
  disk_free=$(df -Pm "$docker_root" 2>/dev/null | awk 'END {print $4}') || {
    fail 'Cannot read free space on the Docker data filesystem; check directory permissions'; return 1;
  }
  (( disk_free >= 25600 )) || { fail "Need 25 GiB free in the Docker data filesystem; found $disk_free MiB"; return 1; }
}
check_kernel() {
  [[ -r /proc/sys/vm/max_map_count ]] || { fail 'Cannot read Linux vm.max_map_count'; return 1; }
  (( $(cat /proc/sys/vm/max_map_count) >= 262144 )) || {
    fail 'Elasticsearch needs vm.max_map_count >= 262144. Run ./deploy.sh to review the installer action'; return 1;
  }
}
preflight() {
  check_host || return 1
  echo '[preflight] Checking project resource ownership.' >&2
  check_compose_ownership || return 1
  echo '[preflight] Checking CPU, RAM, free disk and kernel requirements.' >&2
  check_resources || return 1
  check_kernel || return 1
  echo '[preflight] Checking ports and Compose configuration.' >&2
  check_ports || return 1
  compose config --quiet || { fail 'Docker Compose configuration is invalid'; return 1; }
  echo 'Preflight passed: Docker, permissions, resources, ports and configuration.'
}
