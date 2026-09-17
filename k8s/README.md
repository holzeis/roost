# Deploying Roost to k3s

Mirrors the services in the root `docker-compose.yml`, targeting the
homelab k3s cluster described in `docs/architecture-overview.md`. Every
service is a plain Kubernetes manifest — no Helm.

## Prerequisites

- A k3s cluster with the [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) installed (needed for LiveKit's `LoadBalancer` exposure).
- [Longhorn](https://longhorn.io/) installed, providing a `longhorn` StorageClass. This is a real multi-node cluster (mixed arm64/amd64 hardware), not a single box — k3s's built-in default `local-path` StorageClass ties a volume to whichever node the pod first lands on and doesn't let it follow the pod elsewhere, which breaks on any node failure/drain/reboot. Every PVC below sets `storageClassName: longhorn` for that reason. If your Longhorn install uses a different StorageClass name, update each PVC to match.
- Every image used here (`postgres:16-alpine`, `quay.io/minio/minio`, `livekit/livekit-server`, and the CI-built chat-server image) publishes multi-arch manifests covering both amd64 and arm64, matching `CLAUDE.md`'s requirement and this cluster's mixed Raspberry Pi 4 / ThinkCentre hardware — Kubernetes resolves the right architecture per node automatically, no per-node manifest changes needed.

## Secrets

Created out-of-band (`kubectl create secret ...`, or a secrets manager) —
never committed here. Each manifest's own header comment has the exact
command; this table is the one-page summary. Where a secret is shared by
two services, the same credential value has to be kept in sync manually —
Kubernetes has no way to derive one secret's value from another.

| Secret | Keys | Used by |
|---|---|---|
| `chat-server-tailscale` | `authkey` | chat-server (its own tailnet identity) |
| `postgres-password` | `password` | postgres pod |
| `chat-server-db` | `url` (full `postgres://...` DSN, embedding the same password as `postgres-password`) | chat-server |
| `chat-server-minio` | `access-key`, `secret-key` | both minio pod and chat-server |
| `livekit-config` | `config.yaml` (full LiveKit config, embedding the same key/secret pair as `chat-server-livekit`) | livekit pod |
| `chat-server-livekit` | `api-key`, `api-secret` | chat-server (mints JWTs LiveKit must trust) |

## Order of operations

```sh
kubectl apply -f k8s/namespace.yaml

# create the secrets in the table above, then:

kubectl apply -f k8s/postgres/
kubectl apply -f k8s/minio/
kubectl apply -f k8s/livekit/
kubectl apply -f k8s/chat-server/
kubectl apply -f k8s/network-policies.yaml
```

## Why chat-server has no Service exposure

It's the one fully custom component (architecture doc: "the chat server is
the one fully custom-built core component"), and it joins the tailnet
directly in-process via `tsnet` rather than being exposed by the operator's
generic `LoadBalancer`-class Service — see the "Chat server joins the
tailnet itself" decision in `docs/architecture-overview.md` for why. That
means `k8s/chat-server/deployment.yaml` needs a reusable Tailscale auth key
(`chat-server-tailscale` secret, key `authkey`) rather than the operator
managing its tailnet presence.

## LiveKit's media port range

`docker-compose.yml` exposes LiveKit's full `50000-50100` UDP range because
Docker supports port ranges directly. Kubernetes Services don't — each port
needs its own entry — so `k8s/livekit/deployment.yaml` narrows this to 20
ports (`50000-50019`), enough for several concurrent family-scale calls.
Widen it (both the container ports, the Service ports, and `livekit-config`'s
`port_range_end`) if you need more concurrent call capacity.

## Image

`k8s/chat-server/deployment.yaml` references
`ghcr.io/holzeis/roost-chat-server:latest` — prefer a pinned tag over
`:latest` for anything beyond local testing once CI is pushing images (see
`.github/workflows/ci.yml`).

## Hardening

Every pod sets `runAsNonRoot: true` with an explicit non-root `runAsUser`/
`runAsGroup` (not just relying on whatever a base image's `USER` happens to
default to), drops all Linux capabilities, disables privilege escalation,
and sets the `RuntimeDefault` seccomp profile — Kubernetes' baseline
"restricted" posture. `automountServiceAccountToken: false` everywhere too,
since none of these pods call the Kubernetes API.

- **chat-server** gets the strongest treatment (`readOnlyRootFilesystem:
  true`) since it's our own distroless static binary with nothing to write
  outside its PVC-mounted tsnet state.
- **postgres** uses uid/gid `999`, the official `postgres:16-alpine` image's
  own baked-in user — `fsGroup: 999` is what makes the PVC-mounted data
  directory writable by it once the container is forced non-root from pod
  start (that skips the image entrypoint's usual root-only setup phase).
- **minio** runs as an arbitrary uid `1000`; since that has no `/etc/passwd`
  entry, `$HOME` needs pointing somewhere writable explicitly (an `emptyDir`
  mounted at `/home/minio-user`) or MinIO fails trying to write its local
  config there.
- **livekit**'s uid `1000` is a generic non-root choice, not verified
  against that image's actual internals the way postgres's `999` is — if it
  fails to start with a permissions error, check what uid/gid the image
  itself expects.

`k8s/namespace.yaml` also enforces the Pod Security Standards "restricted"
profile at admission time (`pod-security.kubernetes.io/enforce: restricted`)
— any future pod spec in this namespace that doesn't meet the bar above gets
rejected outright, not just flagged. The Tailscale operator's own proxy
pods run in its own namespace (`tailscale` by default), not `roost`, so
this doesn't affect them.

`k8s/network-policies.yaml` adds a default-deny-ingress policy plus explicit
allows: only chat-server can reach postgres/minio, and only the Tailscale
operator's own proxy pod (a different namespace) can reach livekit.

**Important**: NetworkPolicy objects only do anything if your cluster's CNI
actually enforces them. k3s's default CNI, Flannel, does **not** — it's a
pure overlay network with no policy engine, so these manifests would apply
successfully via `kubectl` and then silently do nothing. Check with
`kubectl get pods -n kube-system` for a policy controller (Calico,
Cilium, kube-router) — if there isn't one, either swap k3s's CNI (`k3s
server --flannel-backend=none` plus installing Calico/Cilium separately) or
add a lightweight policy-only companion like kube-router alongside Flannel.

**Not done yet, deliberately deferred**: chat-server's `DATABASE_URL` uses
`sslmode=disable` — the `postgres:16-alpine` image has no TLS configured out
of the box (no cert/key, `ssl` off in `postgresql.conf`), so this matches
reality rather than being a considered trade-off. That means the
chat-server↔postgres hop is unencrypted cluster-internal traffic, unrelated
to (and not covered by) Tailscale's own WireGuard encryption, which only
applies to the tailnet-facing hops. Worth fixing (enable `ssl = on` with a
cert on the postgres pod, switch the DSN to `sslmode=verify-ca`), but held
until NetworkPolicy enforcement above is confirmed actually working —
that's the more foundational half of the same "who can reach postgres" gap.
