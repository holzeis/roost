# Deploying Roost to k3s

Mirrors the services in the root `docker-compose.yml`, targeting the
homelab k3s cluster described in `docs/architecture-overview.md`.

## Prerequisites

- A k3s cluster with the [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) installed.
- Helm, for the Postgres/MinIO/LiveKit charts (official charts are used
  where available — only the chat server is fully custom, per the
  architecture doc).

## Order of operations

```sh
kubectl apply -f k8s/namespace.yaml

# Secrets referenced by the values files and Deployment below are created
# out-of-band (kubectl create secret ..., or a secrets manager) — never
# committed here. See each values file's comments for the expected keys.

helm install postgres bitnami/postgresql -n roost -f k8s/values/postgres-values.yaml
helm install minio bitnami/minio -n roost -f k8s/values/minio-values.yaml
helm install livekit livekit/livekit-server -n roost -f k8s/values/livekit-values.yaml

kubectl apply -f k8s/chat-server/
```

## Why chat-server has no Helm chart or Service exposure

It's the one fully custom component (architecture doc: "the chat server is
the one fully custom-built core component"), and it joins the tailnet
directly in-process via `tsnet` rather than being exposed by the operator's
generic `LoadBalancer`-class Service — see the "Chat server joins the
tailnet itself" decision in `docs/architecture-overview.md` for why. That
means `k8s/chat-server/deployment.yaml` needs a reusable Tailscale auth key
(`chat-server-tailscale` secret, key `authkey`) rather than the operator
managing its tailnet presence.

## Image

`k8s/chat-server/deployment.yaml` references
`ghcr.io/REPLACE_ME/roost-chat-server:latest` — replace with the real image
path once CI is pushing images (see `.github/workflows/ci.yml`), and prefer
a pinned tag over `:latest` for anything beyond local testing.
