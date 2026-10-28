#!/usr/bin/env bash
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo 'ERROR: Bash 4.3 or newer is required' >&2
  return 1
fi
# Never source .env as shell code. Only documented numeric settings are accepted.
CONFIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_error() { echo "Configuration error: $*" >&2; return 1; }
load_config() {
  local key value line file count=0
  local -A overrides=() values=() allowed=()
  PROJECT_SETTINGS=()
  while IFS='=' read -r key value; do
    [[ "$key" == \#* || -z "$key" ]] && continue
    PROJECT_SETTINGS+=("$key")
    allowed[$key]=1
    values[$key]=$value
    if [[ -v "$key" ]]; then overrides[$key]=${!key}; fi
  done < "$CONFIG_ROOT/.env.example"
  for file in "$CONFIG_ROOT/.state/settings.env" "$CONFIG_ROOT/.env"; do
    [[ -e "$file" ]] || continue
    [[ -r "$file" ]] || { config_error "Cannot read $file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%$'\r'}
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([0-9]+([.][0-9]+)?)$ ]] || {
        config_error "$file: use plain KEY=number lines without shell expressions"; return 1;
      }
      key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
      [[ -n "${allowed[$key]:-}" ]] || { config_error "Unknown setting: $key"; return 1; }
      values[$key]=$value
    done < "$file"
  done
  for key in "${PROJECT_SETTINGS[@]}"; do
    value=${overrides[$key]:-${values[$key]}}
    if [[ "$key" == *_CPUS ]]; then
      [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$value" 'BEGIN {exit !(n>0 && n<=1024)}' || {
        config_error "$key must be a positive CPU count"; return 1;
      }
    else
      [[ "$value" =~ ^[1-9][0-9]{0,7}$ ]] || { config_error "$key must be a positive integer without leading zeros"; return 1; }
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done
  local -A ports=()
  for key in WEB_PORT KIBANA_PORT NODE_PORT ES_PORT API_PORT; do
    value=${!key}
    (( value >= 1024 && value <= 65535 )) || { config_error "$key must be between 1024 and 65535"; return 1; }
    [[ -z "${ports[$value]:-}" ]] || { config_error "$key conflicts with ${ports[$value]}"; return 1; }
    ports[$value]=$key
  done
  (( ES_HEAP_MB * 2 <= ES_MEMORY_MB && LOGSTASH_HEAP_MB * 2 <= LOGSTASH_MEMORY_MB )) || {
    config_error 'Elasticsearch and Logstash memory limits must be at least twice their heaps'; return 1;
  }
  (( KIBANA_HEAP_MB + 256 <= KIBANA_MEMORY_MB )) || {
    config_error 'Kibana memory limit must exceed its heap by at least 256 MiB'; return 1;
  }
  (( WORKER_MEMORY_MB >= APP_MEMORY_LIMIT_MB + FLUENT_MEMORY_LIMIT_MB + 384 && SERVER_MEMORY_MB >= FLUENT_MEMORY_LIMIT_MB + 768 )) || {
    config_error 'Node memory must cover app/collector limits plus K3s overhead'; return 1;
  }
  for key in APP FLUENT; do
    local request="${key}_CPU_REQUEST_MILLICORES" limit="${key}_CPU_LIMIT_MILLICORES"
    (( ${!request} <= ${!limit} )) || { config_error "$request exceeds $limit"; return 1; }
    request="${key}_MEMORY_REQUEST_MB"; limit="${key}_MEMORY_LIMIT_MB"
    (( ${!request} <= ${!limit} )) || { config_error "$request exceeds $limit"; return 1; }
  done
}
save_config() {
  local key settings_tmp
  umask 077
  settings_tmp=$(mktemp "$CONFIG_ROOT/.state/settings.XXXXXX")
  for key in "${PROJECT_SETTINGS[@]}"; do printf '%s=%s\n' "$key" "${!key}"; done > "$settings_tmp"
  mv "$settings_tmp" "$CONFIG_ROOT/.state/settings.env"
}
load_config
