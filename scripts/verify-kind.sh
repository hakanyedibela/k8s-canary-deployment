#!/usr/bin/env bash
# End-to-end test on a throwaway kind cluster:
#   traffic split ~25% canary -> rollback to 0% -> promote under load to 100%.
# Fails on a wrong split, on any non-200 during promotion, or if the old
# version still answers afterwards. Never touches any other kube context.
set -euo pipefail

CLUSTER="canary-verify"
NS=canary
cd "$(dirname "$0")/.."

# Private kubeconfig: kind writes its context here, so ~/.kube/config and its
# current-context stay untouched, and promote.sh can only reach the kind cluster.
TMP=$(mktemp -d)
export KUBECONFIG=$TMP/kubeconfig
k() { kubectl "$@"; }

cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s
for t in 1.0.0 1.0.1; do
  docker image inspect hakanyedibela/go-app:$t >/dev/null 2>&1 || docker pull -q hakanyedibela/go-app:$t
  kind load docker-image --name "$CLUSTER" hakanyedibela/go-app:$t
done

k apply -k manifests

# Proof that the namespace really enforces "restricted": a root Pod is rejected.
if k -n "$NS" run psa-probe --image=busybox:1.36 --restart=Never --dry-run=server -o name >/dev/null 2>&1; then
  echo "FAIL: non-compliant Pod was admitted, Pod Security not enforced"; exit 1
fi
echo "ok: non-compliant Pod rejected by Pod Security admission"

k -n "$NS" rollout status deploy/go-app-stable --timeout=180s
k -n "$NS" rollout status deploy/go-app-canary --timeout=180s

# The namespace enforces "restricted", so the test client must comply too.
k -n "$NS" run client --image=curlimages/curl:8.10.1 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"client","image":"curlimages/curl:8.10.1","command":["sleep","3600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
k -n "$NS" wait --for=condition=Ready pod/client --timeout=120s

# Send N requests to the Service. Prints: <canary hits> <failed requests>.
# 1.0.0 (stable) returns 2 developer records, 1.0.1 (canary) returns 4.
sample() {
  # shellcheck disable=SC2016  # $vars expand inside the client pod
  k -n "$NS" exec client -- sh -c '
    canary=0; fails=0
    for i in $(seq 1 '"$1"'); do
      body=$(curl -sf -m 2 http://go-app/developer) || { fails=$((fails+1)); continue; }
      [ "$(echo "$body" | grep -o first_name | wc -l)" -eq 4 ] && canary=$((canary+1))
      sleep '"${2:-0}"'
    done
    echo "$canary $fails"'
}

wait_endpoints() {  # wait until the Service has exactly $1 ready endpoints
  for _ in $(seq 1 60); do
    n=$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=go-app \
          -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}' | wc -c | tr -d ' ')
    [[ "$n" == "$1" ]] && return 0
    sleep 1
  done
  echo "FAIL: Service never reached $1 ready endpoints (has $n)"; exit 1
}

echo "--- 3 stable + 1 canary: expect ~25% canary"
wait_endpoints 4
read -r canary fails < <(sample 400)
[[ "$fails" == 0 ]] || { echo "FAIL: $fails failed requests"; exit 1; }
# Binomial(400, 0.25): mean 100, sd ~8.7. 40..160 is > 6 sd either side.
(( canary >= 40 && canary <= 160 )) || { echo "FAIL: canary got $canary/400"; exit 1; }
echo "ok: canary served $canary/400 requests"

echo "--- rollback: scale canary to 0, expect 0% canary"
k -n "$NS" scale deploy/go-app-canary --replicas=0
k -n "$NS" rollout status deploy/go-app-canary --timeout=60s
wait_endpoints 3
read -r canary fails < <(sample 200)
[[ "$canary" == 0 && "$fails" == 0 ]] || { echo "FAIL: after rollback canary=$canary fails=$fails"; exit 1; }
echo "ok: 0/200 requests reached canary after rollback"

echo "--- canary back, then promote under load"
k -n "$NS" scale deploy/go-app-canary --replicas=1
k -n "$NS" rollout status deploy/go-app-canary --timeout=60s
wait_endpoints 4
sample 600 0.05 > "$TMP/load" &
load=$!
sleep 2
./scripts/promote.sh
wait $load
read -r _ fails < "$TMP/load"
[[ "$fails" == 0 ]] || { echo "FAIL: $fails failed requests during promotion"; exit 1; }
echo "ok: 0/600 failed requests during promotion"

wait_endpoints 3
read -r canary fails < <(sample 200)
[[ "$canary" == 200 && "$fails" == 0 ]] || { echo "FAIL: after promotion new=$canary/200 fails=$fails"; exit 1; }
echo "ok: 200/200 requests served by the new version"

echo "ALL CHECKS PASSED"
