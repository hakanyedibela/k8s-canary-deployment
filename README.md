# Canary Deployment in Kubernetes

Canary releases with plain Kubernetes objects: two Deployments behind one
Service, traffic split by replica count. No service mesh, no Ingress controller,
no Argo Rollouts. That is exactly the toolset you have in the CKAD exam.

## The idea

You release a new version to **a small share of real traffic first**, watch it,
and only then roll it out to everyone:

- **stable**: the current version (`hakanyedibela/go-app:1.0.0`), 3 replicas
- **canary**: the new version (`1.0.1`), 1 replica

A Service sends traffic to **every ready Pod whose labels match its `selector`**.
Both Deployments share the label `app=go-app`, and the Service selects only on
that label. So it balances across all 4 Pods, and the canary gets about
**1 of 4 requests (~25%)**:

```
                                   ┌──► go-app-stable  app=go-app track=stable  3 Pods, v1.0.0  (~75%)
  clients ──► go-app Service ──────┤
              selector: app=go-app └──► go-app-canary  app=go-app track=canary  1 Pod,  v1.0.1  (~25%)
```

The split is controlled with `kubectl scale`:

| stable : canary | canary share |
|---|---|
| 3 : 1 | ~25% |
| 9 : 1 | ~10% |
| 1 : 1 | ~50% |
| 3 : 0 | 0% (rollback) |

The split is **per connection and random**, not exact. kube-proxy picks an endpoint
at random for each new connection; keep-alive connections stay on the Pod they hit.

## Repository layout

```
manifests/
  namespace.yaml        namespace canary, Pod Security "restricted" enforced
  deploy-stable.yaml    go-app-stable, labels app=go-app track=stable, image 1.0.0, 3 replicas
  deploy-canary.yaml    go-app-canary, labels app=go-app track=canary, image 1.0.1, 1 replica
  service.yaml          go-app: selector app=go-app only, so it covers both tracks
  kustomization.yaml    lets you apply everything with kubectl apply -k
scripts/
  promote.sh            roll the canary image onto stable, then remove the canary
  verify-kind.sh        end-to-end test on a throwaway kind cluster
```

## Walkthrough

### 1. Deploy everything

```shell
kubectl apply -k manifests/
kubectl -n canary rollout status deploy/go-app-stable
kubectl -n canary rollout status deploy/go-app-canary
kubectl -n canary get deploy,svc,pods -L track
```

### 2. Check the Service covers both tracks

```shell
kubectl -n canary describe svc go-app          # "Endpoints:" lists 4 Pod IPs
kubectl -n canary get endpointslices -l kubernetes.io/service-name=go-app
kubectl -n canary get pods -l app=go-app -L track -o wide
```

### 3. Watch the split

Use a temporary Pod and the Service's DNS name. The app returns 2 developers in
1.0.0 and 4 in 1.0.1, so you can see which version answered. The namespace
enforces Pod Security *restricted*, so the test Pod needs a compliant
securityContext too:

```shell
kubectl -n canary run tmp --rm -it --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"tmp","image":"busybox:1.36","stdin":true,"tty":true,"command":["sh","-c","while true; do wget -qO- http://go-app/developer | grep -o first_name | wc -l; sleep 1; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

Mostly `2`, roughly every fourth line `4`. Stop with `Ctrl-C`.

### 4. Shift more traffic to the canary (optional)

```shell
kubectl -n canary scale deploy/go-app-canary --replicas=3   # 3:3 = ~50%
```

### 5a. Rollback: the canary is bad

Remove all canary Pods. Stable was never touched, so it immediately takes 100%.

```shell
kubectl -n canary scale deploy/go-app-canary --replicas=0
```

### 5b. Promote: the canary is good

Roll the canary's image onto stable, then remove the canary Pods:

```shell
kubectl -n canary set image deploy/go-app-stable go-app=hakanyedibela/go-app:1.0.1
kubectl -n canary rollout status deploy/go-app-stable
kubectl -n canary scale deploy/go-app-canary --replicas=0
```

Or with the guard rail (refuses unless the canary is Ready, takes the image from it):

```shell
./scripts/promote.sh
```

Then update the image tag in `manifests/deploy-stable.yaml` and set
`manifests/deploy-canary.yaml` to `replicas: 0`, or the next `kubectl apply -k`
silently reverts the promotion. Git must match the cluster.

### 6. Next release

```shell
kubectl -n canary set image deploy/go-app-canary go-app=hakanyedibela/go-app:1.0.2
kubectl -n canary scale deploy/go-app-canary --replicas=1
```

### Cleanup

```shell
kubectl delete ns canary
```

## What makes the manifests "best practice"

| Setting | Why |
|---|---|
| Service selector `app=go-app` only | Covers both tracks. This shared label is the canary mechanism. |
| Deployment selector includes `track` | Stable and canary must never select each other's Pods, or each Deployment would count and scale down the other's Pods. Selectors are **immutable**, so get this right at creation time. |
| `readinessProbe` on `/developer` | A Pod only receives traffic once the real endpoint answers. A canary that fails to start never gets requests. |
| `livenessProbe` on `/` | Restarts a hung container. Deliberately looser than readiness. |
| `preStop: sleep 5` | When a Pod terminates, the app exits immediately while kube-proxy still routes to it for a moment. Without the hook, the end-to-end test measured **1 failed request out of 600** during promotion; with it, 0. |
| `RollingUpdate` with `maxUnavailable: 0` | Promotion (`set image` on stable) never drops below 3 ready Pods. |
| `resources.requests` + memory `limits` | Scheduler can place Pods correctly; a memory leak gets OOM-killed instead of starving the node. No CPU limit, to avoid throttling. |
| `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ["ALL"]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault` | Meets the Pod Security Standard *restricted* profile, which `namespace.yaml` enforces. The image itself runs as root; the Pod overrides it with UID 65534. |
| `automountServiceAccountToken: false` | The app never calls the API server, so it gets no token. |
| Named port `http` used by Service and probes | Change the container port in one place only. |

## CKAD cheat sheet

Generate instead of typing YAML:

```shell
export do="--dry-run=client -o yaml"
kubectl create deploy go-app-canary --image=hakanyedibela/go-app:1.0.1 --replicas=1 --port=18080 $do > canary.yaml
```

`kubectl create deploy` only sets `app=<deployment name>`. For a canary, edit the
generated YAML: set `app: go-app` and add `track: canary` **in the selector and the
Pod template**, before applying.

Create the Service so it selects only the shared label:

```shell
kubectl -n canary expose deploy go-app-stable --name=go-app --port=80 --target-port=18080 --selector=app=go-app
```

Without `--selector`, `expose` copies the Deployment's full selector (`track=stable`
included) and the canary never gets traffic. This is the most common mistake.

Useful checks:

```shell
kubectl get pods --show-labels
kubectl get pods -l app=go-app,track=canary
kubectl get svc go-app -o jsonpath='{.spec.selector}'
kubectl describe svc go-app                         # look at "Endpoints:"
kubectl rollout history deploy/go-app-stable
kubectl rollout undo deploy/go-app-stable           # undo a bad promotion
```

Canary vs. the other strategies:

| Strategy | Mechanism | Rollback | Cost |
|---|---|---|---|
| `RollingUpdate` (default) | Pods replaced gradually within one Deployment; you can't hold at a percentage | `kubectl rollout undo`, gradual | No extra capacity |
| `Recreate` | All old Pods killed, then new ones started | Redeploy | Downtime |
| Blue-green | Two Deployments, Service selector switch; exactly **one** version serves | Patch selector back, instant | 2x capacity while both run |
| Canary (this repo) | Two Deployments behind **one** shared label; traffic split by replica ratio | Scale canary to 0, instant | Small extra capacity |

## Limits of this approach

- **Coarse split.** The share is a replica ratio. 1% needs 99 stable Pods. For exact
  percentages, header-based routing, or sticky users, use Gateway API, an Ingress
  controller with canary support (e.g. ingress-nginx annotations), or a service mesh.
- **No sticky sessions.** The same user can hit stable on one request and canary on the
  next. Both versions must be compatible with each other's data and API.
- **No automated analysis.** Watching metrics and deciding to promote or roll back is
  manual here. Argo Rollouts or Flagger automate that.
- **Database schema changes** must work for both versions at once. Use expand/contract
  migrations.
- **The image** (`hakanyedibela/go-app`) is **arm64-only** and ~900 MB (full `golang`
  base image). It will not start on amd64 nodes. A multi-stage build onto a
  `distroless`/`scratch` base with `--platform linux/amd64,linux/arm64` fixes both.
  The `preStop` hook uses the `sleep` binary from the current base image; on a
  `scratch` image switch to `lifecycle.preStop.sleep.seconds: 5` (Kubernetes 1.30+).

## Verify it yourself

`scripts/verify-kind.sh` creates a throwaway kind cluster and checks:

1. a root Pod is rejected by Pod Security admission
2. with 3 stable + 1 canary, the canary serves a plausible share of 400 requests
3. after scaling the canary to 0, no request reaches it
4. during promotion under load (600 requests), **no request fails**
5. after promotion, every request is served by the new version

It uses a private kubeconfig, so your current `kubectl` context is never touched,
and deletes the cluster at the end.

```shell
./scripts/verify-kind.sh
```

Requires Docker, `kind`, and `kubectl`.
