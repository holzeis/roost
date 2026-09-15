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
