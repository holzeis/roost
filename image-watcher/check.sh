#!/bin/sh
# Restarts chat-server once the digest ghcr.io publishes for :latest changes
# — see k8s/image-watcher.yaml for how this runs (a CronJob, RBAC scoped to
# exactly this) and k8s/README.md's "Deploying automatically after a push
# to main" section for the overall design.
set -eu

NAMESPACE="roost"
CONFIGMAP="image-watch-state"
OWNER="holzeis"

# Prints the manifest-list digest currently published for :latest — this is
# what changes on every push to main, regardless of which platform
# (amd64/arm64) a given pod happens to be running on.
get_digest() {
  repo="$1"
  token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" | jq -r .token)
  curl -fsSL \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    -D - -o /dev/null \
    "https://ghcr.io/v2/${repo}/manifests/latest" \
    | tr -d '\r' | grep -i '^docker-content-digest:' | awk '{print $2}'
}

kubectl -n "$NAMESPACE" create configmap "$CONFIGMAP" 2>/dev/null || true

check_and_restart() {
  component="$1"
  deployment="$2"
  repo="${OWNER}/roost-${component}"

  current=$(get_digest "$repo")
  if [ -z "$current" ]; then
    echo "$component: could not fetch digest, skipping"
    return
  fi

  previous=$(kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" -o "jsonpath={.data.${component}}" 2>/dev/null || true)

  if [ "$current" = "$previous" ]; then
    echo "$component: unchanged"
    return
  fi

  if [ -n "$previous" ]; then
    echo "$component: digest changed, restarting deployment/$deployment"
    kubectl -n "$NAMESPACE" rollout restart "deployment/${deployment}"
  else
    echo "$component: first run, recording current digest without restarting"
  fi

  kubectl -n "$NAMESPACE" patch configmap "$CONFIGMAP" --type merge -p "{\"data\":{\"${component}\":\"${current}\"}}"
}

check_and_restart chat-server chat-server
