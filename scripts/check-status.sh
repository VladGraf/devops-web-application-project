#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
k() { kubectl --context k3d-final-project -n final-project "$@"; }
failed=0
bad() { echo "FAIL: $*" >&2; failed=1; }
echo '=== Docker services ==='
for service in nginx elasticsearch logstash kibana; do
  health=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "final-project-$service") || {
    bad "$service is missing"; continue;
  }
  echo "$service: $health"
  [[ "$health" == 'running healthy' ]] || bad "$service is not healthy"
done
echo '=== K3s nodes and application ==='
if bash scripts/cluster.sh verify; then
  kubectl --context k3d-final-project get nodes -o wide || bad 'Cannot read nodes'
  kubectl --context k3d-final-project wait nodes --all --for=condition=Ready --timeout=15s || bad 'Nodes are not Ready'
else
  bad 'Cluster shape or network is wrong'
fi
k get deployments,pods,services -o wide || bad 'Cannot read app resources'
k rollout status deployment/web-app --timeout=15s || bad 'App rollout is unhealthy'
k rollout status daemonset/fluent-bit --timeout=15s || bad 'Fluent Bit rollout is unhealthy'
# Rollout status alone does not ensure all desired replicas still exist and are Ready.
app=$(k get deployment web-app -o json) || app='{}'
jq -e '.spec.replicas == 3 and .status.readyReplicas == 3 and .status.updatedReplicas == 3 and .status.availableReplicas == 3' <<< "$app" >/dev/null || bad 'Expected 3 Ready app replicas'
collector=$(k get daemonset fluent-bit -o json) || collector='{}'
jq -e '.status.desiredNumberScheduled == 3 and .status.numberReady == 3 and .status.numberAvailable == 3' <<< "$collector" >/dev/null || bad 'Expected 3 Ready Fluent Bit collectors'
echo '=== Resource usage ==='
kubectl --context k3d-final-project top nodes || echo 'Resource metrics are not available yet.'
echo '=== HTTP health ==='
for url in http://127.0.0.1:${WEB_PORT:-8088}/nginx-health http://127.0.0.1:${WEB_PORT:-8088}/readyz; do
  curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "$url" || bad "HTTP check: $url"
  echo
done
elastic=$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:${ES_PORT:-19200}/_cluster/health) || elastic='{}'
jq -e '.status == "green" or .status == "yellow"' <<< "$elastic" >/dev/null || bad 'Elasticsearch cluster is not usable'
app_health=$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:${WEB_PORT:-8088}/api/status) || app_health='{}'
echo "$app_health"
jq -e '.status == "healthy"' <<< "$app_health" >/dev/null || bad 'App status is unhealthy'
kibana=$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:${KIBANA_PORT:-5601}/api/status) || kibana='{}'
jq -e '.status.overall.level == "available"' <<< "$kibana" >/dev/null || bad 'Kibana is unavailable'
echo '=== End-to-end log delivery ==='
# This GET creates one uniquely identifiable app log. No cluster writes are needed.
marker="final-project-check-$(cat /proc/sys/kernel/random/uuid)"
curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:${WEB_PORT:-8088}/healthz?check=$marker" >/dev/null || bad 'Could not create the test request'
query=$(jq -nc --arg marker "$marker" '{size:0,query:{bool:{filter:[{match_phrase:{project:"final-project"}},{match_phrase:{log:$marker}}]}}}')
delivered=0
for ((attempt=0; attempt<20; attempt++)); do
  result=$(curl --fail --silent --show-error --max-time 5 \
    -H 'Content-Type: application/json' \
    -d "$query" "http://127.0.0.1:${ES_PORT:-19200}/final-project-logs-*/_search?allow_no_indices=true") || result='{}'
  if jq -e '.hits.total.value > 0' <<< "$result" >/dev/null; then
    delivered=1
    break
  fi
  sleep 3
done
[[ "$delivered" == 1 ]] && echo 'PASS: request reached Elasticsearch through Fluent Bit and Logstash.' || bad 'Test request did not reach Elasticsearch; check Fluent Bit and Logstash.'
exit "$failed"
