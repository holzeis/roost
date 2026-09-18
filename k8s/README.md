# Deploying Roost to k3s

Mirrors the services in the root `docker-compose.yml`, targeting the
homelab k3s cluster described in `docs/architecture-overview.md`. Every
service is a plain Kubernetes manifest — no Helm.

## Prerequisites

- A k3s cluster. The [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) is **not** required — both services that need tailnet reachability provide it themselves (chat-server embeds `tsnet`; LiveKit runs a Tailscale sidecar), so nothing here depends on the operator's `LoadBalancer` exposure.
- [Longhorn](https://longhorn.io/) installed, providing a `longhorn` StorageClass. This is a real multi-node cluster (mixed arm64/amd64 hardware), not a single box — k3s's built-in default `local-path` StorageClass ties a volume to whichever node the pod first lands on and doesn't let it follow the pod elsewhere, which breaks on any node failure/drain/reboot. Every PVC below sets `storageClassName: longhorn` for that reason. If your Longhorn install uses a different StorageClass name, update each PVC to match.
- Every image used here (`postgres:16-alpine`, `quay.io/minio/minio`, `livekit/livekit-server`, and the CI-built chat-server image) publishes multi-arch manifests covering both amd64 and arm64, matching `CLAUDE.md`'s requirement and this cluster's mixed Raspberry Pi 4 / ThinkCentre hardware — Kubernetes resolves the right architecture per node automatically, no per-node manifest changes needed.

## Secrets

Created out-of-band (`kubectl create secret ...`, or a secrets manager) —
never committed here. Each manifest's own header comment has the exact
command; this table is the one-page summary. Where a secret is shared by
two services, the same credential value has to be kept in sync manually —
Kubernetes has no way to derive one secret's value from another.

Note the namespace column — LiveKit's two secrets live in `roost-media`,
everything else in `roost`.

| Secret | Namespace | Keys | Used by |
|---|---|---|---|
| `chat-server-tailscale` | `roost` | `authkey` | chat-server (its own tailnet identity) |
| `postgres-password` | `roost` | `password` | postgres pod |
| `chat-server-db` | `roost` | `url` (full `postgres://...` DSN, embedding the same password as `postgres-password`) | chat-server |
| `chat-server-minio` | `roost` | `access-key`, `secret-key` | both minio pod and chat-server |
| `chat-server-livekit` | `roost` | `api-key`, `api-secret` | chat-server (mints JWTs LiveKit must trust) |
| `livekit-config` | `roost-media` | `config.yaml` (full LiveKit config, embedding the same key/secret pair as `chat-server-livekit`, plus `rtc.node_ip`) | livekit pod |
| `livekit-tailscale` | `roost-media` | `authkey` | LiveKit's Tailscale sidecar |

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

## LiveKit's two-phase `node_ip` setup

LiveKit has to advertise an ICE candidate address clients can route to, and
that address is the tailnet IP its sidecar gets — which isn't known until
the pod has registered once. So the first deploy is two-phase:

```sh
# 1. Deploy without node_ip. The pod starts; LiveKit works for signaling
#    but media won't connect yet.
kubectl apply -f k8s/livekit/

# 2. Read the tailnet IP the sidecar registered (or find roost-livekit in
#    `tailscale status` / the admin console):
kubectl exec -n roost-media deploy/livekit -c tailscale -- tailscale ip -4

# 3. Put that address in the config's rtc.node_ip and restart:
#    (recreate the livekit-config secret with `node_ip: <that address>`
#    under the rtc: block, then)
kubectl rollout restart deploy/livekit -n roost-media
```

The sidecar's state lives on a PVC, so the identity and IP stay stable
across restarts — this is a one-time step, not something to redo on every
deploy. If you ever delete that PVC, the node re-registers with a new
address and `node_ip` has to be updated to match.

## Why chat-server has no Service exposure

It's the one fully custom component (architecture doc: "the chat server is
the one fully custom-built core component"), and it joins the tailnet
directly in-process via `tsnet` rather than being exposed by the operator's
generic `LoadBalancer`-class Service — see the "Chat server joins the
tailnet itself" decision in `docs/architecture-overview.md` for why. That
means `k8s/chat-server/deployment.yaml` needs a reusable Tailscale auth key
(`chat-server-tailscale` secret, key `authkey`) rather than the operator
managing its tailnet presence.

## Why LiveKit is its own tailnet node

Same reason as chat-server, reached from the opposite direction. LiveKit was
originally exposed through the Tailscale operator's `LoadBalancer`-class
Service, which is fine for TCP signaling but breaks WebRTC media: an SFU has
to advertise ICE candidates clients can actually route to, and LiveKit —
seeing only its pod IP behind the proxy — advertised `10.42.x.x`, which no
phone on the tailnet can reach. Calls connected to signaling and then died
with `Timed Out waiting for PeerConnection to connect`.

A Tailscale sidecar sharing the pod's network namespace fixes it: the pod
gets a real `100.x.y.z` address, `rtc.node_ip` points at it, and media flows
client→pod directly over WireGuard with full UDP. That also means **LiveKit
has no Service at all** now, exactly like chat-server — nothing in-cluster
connects to it (chat-server only mints JWTs locally; it never opens a
connection), and clients reach it at `roost-livekit.<tailnet>.ts.net`.

The media port range (`50000-50019` in the config) no longer has to be
enumerated anywhere, since nothing proxies it — widen it in `livekit-config`
alone if you need more concurrent call capacity.

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
rejected outright, not just flagged.

**The one deliberate carve-out**: LiveKit lives in a separate `roost-media`
namespace enforcing `baseline` rather than `restricted`, because its
Tailscale sidecar needs `NET_ADMIN` to bring up a kernel-mode tailnet
interface — and `restricted` forbids adding any capability. The alternatives
were worse: `hostNetwork` (forbidden by `baseline` too, and it would expose
the node's whole network stack rather than one pod's), or userspace-mode
Tailscale (no added capability, but it forwards inbound UDP poorly — which
is exactly what the media path needs). Isolating it in its own namespace
keeps `roost` fully restricted instead of loosening everything for one pod's
requirement, and `baseline` still blocks privileged containers, host
namespaces, hostPath volumes and host ports. LiveKit's own container within
that pod remains non-root with all capabilities dropped; only the sidecar
holds the extra privilege.

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
