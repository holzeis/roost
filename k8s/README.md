# Deploying Roost to k3s

Mirrors the services in the root `docker-compose.yml`, targeting the
homelab k3s cluster described in `docs/architecture-overview.md`. Every
service is a plain Kubernetes manifest — no Helm.

## Prerequisites

- A k3s cluster. The [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) is **not** required — both services that need tailnet reachability provide it themselves (chat-server embeds `tsnet`; LiveKit runs a Tailscale sidecar), so nothing here depends on the operator's `LoadBalancer` exposure.
- [Longhorn](https://longhorn.io/) installed, providing a `longhorn` StorageClass. This is a real multi-node cluster (mixed arm64/amd64 hardware), not a single box — k3s's built-in default `local-path` StorageClass ties a volume to whichever node the pod first lands on and doesn't let it follow the pod elsewhere, which breaks on any node failure/drain/reboot. Every PVC below sets `storageClassName: longhorn` for that reason. If your Longhorn install uses a different StorageClass name, update each PVC to match.
- Every image used here (`postgres:16-alpine`, `quay.io/minio/minio`, `livekit/livekit-server`, and the CI-built chat-server image) publishes multi-arch manifests covering both amd64 and arm64, matching `CLAUDE.md`'s requirement and this cluster's mixed Raspberry Pi 4 / ThinkCentre hardware — Kubernetes resolves the right architecture per node automatically, no per-node manifest changes needed.

## Secrets

One Secret, `roost-secrets`, holds every credential. Each value appears
exactly once — no copy of the same password in two places to keep in sync.
Where a value needs to appear inside a larger string (the Postgres DSN,
LiveKit's config file), the manifests compose it at runtime with
Kubernetes' `$(VAR)` env interpolation rather than storing a second
pre-assembled copy.

| Key | Used by |
|---|---|
| `chat-server-authkey` | chat-server's `tsnet` node, at first registration only |
| `livekit-authkey` | LiveKit's Tailscale sidecar, at first registration only |
| `postgres-password` | the postgres pod, and chat-server (which interpolates it into `DATABASE_URL`) |
| `minio-access-key`, `minio-secret-key` | the minio pod, and chat-server's S3 client |
| `livekit-api-key`, `livekit-api-secret` | chat-server (mints JWTs) and LiveKit (validates them) — interpolated into LiveKit's `keys:` config |
| `livekit-node-ip` | LiveKit's advertised ICE address; not actually secret, but deployment-specific, so it lives with the other per-cluster values you fill in. See the two-phase setup below |
| `apns-key-id`, `apns-team-id`, `apns-private-key` | chat-server's APNs client (FR5.1 call-wake push to iOS) — see `docs/ios-dev-setup.md` for where these come from. Optional (`optional: true` in the Deployment): omit all three and the server falls back to `push.NoopSender` |
| `fcm-service-account-json` | chat-server's FCM client (FR5.1 call-wake push to Android) — the service-account JSON downloaded from Firebase Console → Project Settings → Service Accounts. Also optional |

Create it in one command (never committed — generate the values here):

```sh
kubectl create secret generic roost-secrets -n roost \
  --from-literal=chat-server-authkey='<tskey-auth-...>' \
  --from-literal=livekit-authkey='<a different tskey-auth-...>' \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --from-literal=minio-access-key='roost' \
  --from-literal=minio-secret-key="$(openssl rand -base64 24)" \
  --from-literal=livekit-api-key='roost' \
  --from-literal=livekit-api-secret="$(openssl rand -base64 32)" \
  --from-literal=livekit-node-ip=''
```

Push (FR5.1) is optional and can be added later, once Apple/Firebase credentials exist:

```sh
kubectl patch secret roost-secrets -n roost --type=merge -p="$(cat <<EOF
{"stringData": {
  "apns-key-id": "<key id>",
  "apns-team-id": "<team id>",
  "apns-private-key": "$(cat AuthKey_XXXXXXXXXX.p8)",
  "fcm-service-account-json": "$(cat service-account.json)"
}}
EOF
)"
```

`livekit-node-ip` starts empty and gets filled in after the first deploy —
see below. LiveKit's API secret must be at least 32 characters, which
`openssl rand -base64 32` satisfies.

**The two Tailscale keys must be different keys.** An auth key is redeemed
at registration, and the admin console only offers single-use keys on some
tailnets — so one key cannot enrol both services. This only bites on a
first deploy: each pod persists its node identity on its own PVC afterwards
and never re-authenticates, which is why chat-server keeps working
indefinitely on a key that's long since been spent. If you ever lose one of
those PVCs, that service needs a fresh key to re-register.

To rotate any value, patch that one key and restart the pods that read it;
nothing else needs updating:

```sh
kubectl patch secret roost-secrets -n roost \
  -p "{\"stringData\":{\"postgres-password\":\"$(openssl rand -base64 24)\"}}"
```

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
# 1. Deploy with livekit-node-ip still empty. The pod starts and signaling
#    works, but media won't connect yet.
kubectl apply -f k8s/livekit/

# 2. Read the tailnet IP the sidecar registered (or find roost-livekit in
#    `tailscale status` / the admin console):
kubectl exec -n roost deploy/livekit -c tailscale -- tailscale ip -4

# 3. Patch that one key and restart:
kubectl patch secret roost-secrets -n roost \
  -p '{"stringData":{"livekit-node-ip":"100.x.y.z"}}'
kubectl rollout restart deploy/livekit -n roost
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
(`roost-secrets`, key `chat-server-authkey`) rather than the operator
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

The media port range (`50000-50019`) no longer has to be enumerated
anywhere, since nothing proxies it — widen it in the `LIVEKIT_CONFIG` block
in `k8s/livekit/deployment.yaml` alone if you need more concurrent call
capacity.

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

The one exception is **LiveKit's Tailscale sidecar**, which needs
`NET_ADMIN` to bring up a kernel-mode tailnet interface. LiveKit's own
container in that pod still runs non-root with all capabilities dropped —
only the sidecar holds the extra privilege, and it's what makes the media
path work at all (userspace-mode Tailscale avoids the capability but
forwards inbound UDP poorly; `hostNetwork` would expose the whole node's
network stack rather than one pod's, which is strictly worse).

**No Pod Security Standards labels are set on the namespace**, deliberately.
An earlier revision enforced `restricted`, but *both* `restricted` and
`baseline` forbid adding `NET_ADMIN` — restricted requires dropping all
capabilities and permits adding only `NET_BIND_SERVICE`, and baseline
permits only the default capability set, which doesn't include `NET_ADMIN`
either. Keeping admission enforcement would have meant either a PSS
exemption configured at the API-server level (`AdmissionConfiguration`, not
expressible in a manifest and requiring k3s server config changes) or
splitting LiveKit into its own unlabelled namespace — neither justified by
the benefit, since the PSS labels were only ever an admission-time backstop.
The actual hardening is in each pod's own `securityContext` above, and all
of it remains in force. What's lost is the guarantee that a future careless
manifest can't silently regress it.

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
