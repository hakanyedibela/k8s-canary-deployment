#!/usr/bin/env bash
# Promote the canary: roll its image onto the stable Deployment, then remove
# the canary Pods. Refuses unless the canary is fully rolled out and ready.
set -euo pipefail

NS=${NS:-canary}
echo "context: $(kubectl config current-context)  namespace: $NS"

kubectl -n "$NS" rollout status deploy/go-app-canary --timeout=120s
ready=$(kubectl -n "$NS" get deploy go-app-canary -o jsonpath='{.status.readyReplicas}')
if [[ "${ready:-0}" -lt 1 ]]; then
  echo "go-app-canary has no ready Pods, nothing to promote" >&2
  exit 1
fi

image=$(kubectl -n "$NS" get deploy go-app-canary -o jsonpath='{.spec.template.spec.containers[?(@.name=="go-app")].image}')
echo "promoting $image to go-app-stable"

kubectl -n "$NS" set image deploy/go-app-stable go-app="$image"
kubectl -n "$NS" rollout status deploy/go-app-stable --timeout=180s
kubectl -n "$NS" scale deploy/go-app-canary --replicas=0

kubectl -n "$NS" get deploy -L track -o wide
