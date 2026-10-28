#!/usr/bin/env bash
# No commands run when this file is sourced.
run_deployment_logged() {
  local root=$1 approval=$2 log_dir log_file result filter_status output_status awk_version
  local -a results redactor=(awk)
  log_dir="$root/.state/logs"
  command -v awk >/dev/null || {
    echo 'ERROR: the base OS awk command is needed for safe deployment logging. Restore it before retrying.' >&2
    return 1
  }
  if [[ -L "$root/.state" || -L "$log_dir" ]]; then
    echo 'ERROR: project state and log directories must not be symbolic links.' >&2
    return 1
  fi
  umask 077
  mkdir -p "$log_dir" || { echo 'ERROR: cannot create project log directory.' >&2; return 1; }
  chmod 700 "$root/.state" "$log_dir" || return 1
  log_file=$(mktemp "$log_dir/deploy-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log") || return 1
  # mawk buffers pipe input even when the AWK program calls fflush().
  # Its interactive mode processes each incoming line without waiting for EOF.
  awk_version=$(awk -W version 2>&1) || awk_version=''
  if [[ "$awk_version" == mawk\ * ]]; then redactor+=(-W interactive); fi
  if "${redactor[@]}" -f "$root/scripts/redact.awk" </dev/null >/dev/null; then :;
  else
    filter_status=$?
    printf 'ERROR: deployment log recording failed (redactor=%d). Log: %s\n' "$filter_status" "$log_file" >&2
    return "$filter_status"
  fi
  printf 'Deployment log: %s\n' "$log_file"
  # Redact before tee: no raw output is saved, even temporarily.
  # stdin remains the caller's terminal, so installation confirmation still works.
  set +e
  {
    printf 'DevOps Web Application Project\nStarted (UTC): %s\n' "$(date -u +%FT%TZ)"
    bash "$root/scripts/deploy-project.sh" "$approval"
    result=$?
    printf '\nDeployment exit_code=%d\nFinished (UTC): %s\n' "$result" "$(date -u +%FT%TZ)"
    exit "$result"
  } 2>&1 | "${redactor[@]}" -f "$root/scripts/redact.awk" | tee -a "$log_file"
  results=("${PIPESTATUS[@]}")
  set -e
  result=${results[0]}; filter_status=${results[1]}; output_status=${results[2]}
  if (( filter_status != 0 || output_status != 0 )); then
    echo "ERROR: deployment log recording failed (redactor=$filter_status, writer=$output_status)." >&2
    (( result != 0 )) || result=1
  fi
  if (( result != 0 )); then
    printf 'Deployment failed (exit_code=%d). Log: %s\n' "$result" "$log_file" >&2
  else
    printf 'Deployment completed. Log: %s\n' "$log_file"
  fi
  return "$result"
}
