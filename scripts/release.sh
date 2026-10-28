#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
k() { kubectl --context k3d-final-project -n final-project "$@"; }
bash scripts/cluster.sh verify
mode=${1:?Expected deploy, update or rollback}
[[ "$mode" == deploy || "$mode" == update || "$mode" == rollback ]] || exit 2
state=$(k get deployment web-app --ignore-not-found -o json)
current=''
previous=''
recover=0
retry_version=v1
if [[ -n "$state" ]]; then
  live_image=$(jq -r '.spec.template.spec.containers[] | select(.name=="web-app") | .image' <<< "$state")
  recorded=$(jq -r '.metadata.annotations["final-project.io/current-image"] // ""' <<< "$state")
  previous=$(jq -r '.metadata.annotations["final-project.io/previous-image"] // ""' <<< "$state")
  if [[ "$mode" != update ]] && ! jq -e '
    .spec.replicas as $desired |
    .status.observedGeneration == .metadata.generation and
    .status.updatedReplicas == $desired and
    .status.readyReplicas == $desired and
    .status.availableReplicas == $desired and
    all(.status.conditions[]?; .type != "Progressing" or .status != "False")
  ' <<< "$state" >/dev/null; then
    echo 'Existing deployment is not ready; applying recovery before waiting.'
    recover=1
    # Only a committed, previously healthy release is a rollback candidate.
    current=$recorded
    case "$live_image" in
      final-project-web:v1|final-project-web:v1-*) retry_version=v1;;
      final-project-web:v2|final-project-web:v2-*) retry_version=v2;;
      *) echo 'Cannot recover an unrecognized project image version' >&2; exit 1;;
    esac
  else
    if [[ "$mode" == update ]]; then
      k rollout status deployment/web-app --timeout=240s
    fi
    current=$live_image
    [[ -z "$recorded" || "$recorded" == "$current" ]] || {
      echo 'Image differs from recorded release. Inspect the Deployment before continuing.' >&2; exit 1;
    }
  fi
fi
build_release() {
  local version=$1 digest
  digest=$({ sha256sum app/Dockerfile app/server.py app/index.html; printf 'APP_VERSION=%s\n' "$version"; } | sha256sum | cut -d ' ' -f1)
  target="final-project-web:${version}-${digest}"
  if ! docker image inspect "$target" >/dev/null 2>&1; then
    docker build --load --label "final-project.release=$digest" --build-arg "APP_VERSION=$version" -t "$target" ./app
  fi
  [[ "$(docker image inspect -f '{{index .Config.Labels "final-project.release"}}' "$target")" == "$digest" ]] || {
    echo 'Release image tag collision; refusing to overwrite it' >&2; exit 1;
  }
  k3d image import "$target" -c final-project
}
case "$mode" in
  deploy)
    if (( recover )); then build_release "$retry_version";
    elif [[ -n "$current" ]]; then target=$current;
    else build_release v1; fi
    ;;
  update)
    [[ -n "$current" ]] || { echo 'Deploy the app first' >&2; exit 1; }
    build_release v2
    ;;
  rollback)
    [[ "$previous" =~ ^final-project-web:v[12](-[a-zA-Z0-9_.-]+)?$ && "$previous" != "$current" ]] || {
      echo 'No previous working release is recorded' >&2; exit 1;
    }
    target=$previous
    # Keep release images on the host for recovery and import to all nodes again.
    docker image inspect "$target" >/dev/null
    if [[ "$target" =~ -([0-9a-f]{64})$ ]]; then
      [[ "$(docker image inspect -f '{{index .Config.Labels "final-project.release"}}' "$target")" == "${BASH_REMATCH[1]}" ]] || {
        echo 'Previous release image label does not match its recorded tag' >&2; exit 1;
      }
    fi
    k3d image import "$target" -c final-project
    ;;
esac
if [[ "$mode" == deploy ]]; then
  # The checked-in manifest is a template. Rendering avoids resetting to v1.
  python3 scripts/render-app.py "$target" |
    kubectl --context k3d-final-project apply -f -
  if (( recover )); then
    applied=$(k get deployment web-app -o json)
    if [[ "$(jq -Sc '.spec.template' <<< "$state")" == "$(jq -Sc '.spec.template' <<< "$applied")" ]]; then
      echo 'Failed Deployment template is unchanged; restarting web-app only.'
      k rollout restart deployment/web-app
    fi
  fi
elif [[ "$target" != "$current" ]]; then
  k set image deployment/web-app "web-app=$target"
fi
if ! k rollout status deployment/web-app --timeout=240s; then
  if [[ -n "$current" && "$target" != "$current" ]]; then
    echo 'Release failed. Restoring the last working image.' >&2
    k set image deployment/web-app "web-app=$current"
    k rollout status deployment/web-app --timeout=240s
  fi
  exit 1
fi
# Commit history only after Kubernetes reports a healthy rollout.
if [[ -n "$current" && "$target" != "$current" ]]; then previous=$current; fi
k annotate deployment/web-app --overwrite \
  "final-project.io/current-image=$target" "final-project.io/previous-image=$previous"
echo "Working release: $target"
