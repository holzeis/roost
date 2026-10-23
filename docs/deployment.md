# Deploying Roost

The Kubernetes manifests are **not in this repo**: the homelab k3s cluster is
managed with Flux from a separate repository. This repo builds and publishes
the images; this page is the contract a deployment has to meet. (The manifests
that used to live in `k8s/` are in git history up to the commit that removed
them, if you want to see one.) `docker-compose.yml` is the reference for how
the services fit together locally.

## Images

CI (`.github/workflows/ci.yml`) builds each for **amd64 and arm64** and, on a
push to main that changed `server/`, publishes them to GHCR tagged with the version, the git sha
and `latest`. The **version** is the number of commits in main's history
(`git rev-list --count`), so `roost-chat-server:412` is newer than `:398`. It is
also stamped into the binary (logged at startup as `version`) and set as the
`org.opencontainers.image.version` label. Pin a deployment to a version tag
rather than `latest`:

| Image | What it is |
|---|---|
| `ghcr.io/holzeis/roost-chat-server` | The chat server |
| `ghcr.io/holzeis/roost-alert-bridge` | The Alertmanager bridge (optional) |

Postgres, SeaweedFS (S3) and LiveKit are the stock upstream images; the
architecture doc says why those were chosen. Packages on GHCR must be public,
or the cluster needs an `imagePullSecret`.

Nothing deploys itself from this repo. To run a new version, roll the
Deployment (restart it if it tracks `:latest`, or bump the tag in the Flux
repo). The chat server applies pending schema migrations itself at startup, so
that is the whole procedure. **Roll the server out before shipping an app
version that needs a new endpoint or migration.**

## chat-server

It joins the tailnet itself with `tsnet` and listens on port 80 of the tailnet
node. It has no Service or Ingress, and there is nothing to expose
(architecture overview: "Chat server joins the tailnet itself"). It needs a
persistent volume for `TSNET_STATE_DIR`, so the node keeps its identity across
restarts, and it should use the `Recreate` strategy, since two pods must never
share that volume.

| Variable | Meaning |
|---|---|
| `TSNET_HOSTNAME` | Its MagicDNS name (`roost-chat`; the app's `API_BASE_URL` points at it) |
| `TSNET_STATE_DIR` | Where the tsnet state lives (a persistent volume) |
| `TSNET_AUTHKEY` | Tailscale auth key, used only for the first registration |
| `DATABASE_URL` | Postgres DSN |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_USE_SSL`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | Object storage for media (bucket defaults to `roost-media`) |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | The server only mints call tokens, it never connects to LiveKit |
| `ALERT_BOT_TAG` | ACL tag of the alert bridge's node. Default `tag:roost-alerts` |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_PRODUCTION`, `APNS_BUNDLE_ID` | iOS push, optional (without them push is a no-op). `APNS_PRODUCTION=true` for TestFlight/App Store builds. See `docs/ios-dev-setup.md` |
| `FCM_SERVICE_ACCOUNT_JSON` | Android push, optional. The Firebase service-account JSON |
| `GOOGLE_MAPS_STATIC_API_KEY` | Map snapshots of ended location shares, optional. A Maps Static API key restricted by IP |
| `LISTEN_ADDR` | Defaults to `:8080` (the tailnet listener is separate) |

A health endpoint for liveness and readiness probes (`/healthz`) is served on
port **9000**. The container is distroless and runs as non-root with a
read-only root filesystem; it only writes to the tsnet state directory.

Credentials (auth keys, database and S3 passwords, LiveKit secret, push keys)
belong in Secrets managed outside this repo; never commit them. Where a value
has to appear inside a larger string (such as the Postgres password in
`DATABASE_URL`), compose it at runtime rather than storing a second copy.

**The chat server and the alert bridge need different Tailscale auth keys.**
Many tailnets only offer single-use keys, and a key is spent at registration.
That only matters on a first deploy or after losing a state volume.

## LiveKit

LiveKit is its own tailnet node, via a Tailscale sidecar in the same pod, so it
gets a real `100.x.y.z` address. Behind a proxy it advertised its pod IP, which
no phone can reach, and calls timed out connecting media. Therefore:

- it has no Service, and clients reach it at `roost-livekit` (the app's
  `LIVEKIT_URL`);
- `rtc.node_ip` must be the sidecar's tailnet IP. That is unknown until the pod
  has registered once, so the first deploy is two-phase: deploy with it empty
  (signalling works, media doesn't), read the IP with
  `tailscale ip -4` in the sidecar, set it, restart. The sidecar's state is
  persistent, so the IP then stays stable;
- the sidecar needs `NET_ADMIN` (kernel-mode tailnet interface, for UDP). Give
  the LiveKit container itself no extra privileges. Because of this the
  namespace can't enforce the `baseline` or `restricted` Pod Security Standards.
- the API secret must be at least 32 characters.

## Alert bridge (FR8.1)

The bridge turns Alertmanager webhooks into messages from the "Prometheus"
identity. Its identity is its tailnet ACL tag, so there is no token. One-time
setup, outside the cluster:

1. In the tailnet policy, declare the tag and who may create nodes with it
   (`"tagOwners": { "tag:roost-alerts": ["autogroup:admin"] }`), and let
   `tag:roost-alerts` reach the chat server on port 80.
2. Create an auth key **with that tag** and give it to the bridge as
   `TSNET_AUTHKEY`. The chat server refuses any other tagged node.
3. Run it with `TSNET_HOSTNAME` (e.g. `roost-alerts`), `TSNET_STATE_DIR` (a
   persistent volume), and `ROOST_URL` set to the chat server's MagicDNS name
   (`http://roost-chat`). It listens on 8080; expose it as a cluster Service
   (port 80) and allow only the namespace that runs Alertmanager to reach it.
4. Point Alertmanager at `/alerts`, and the always-firing `Watchdog` alert at
   `/watchdog` with a 24h `repeat_interval`:

   ```yaml
   receivers:
     - name: roost
       webhook_configs:
         - url: http://alert-bridge.roost.svc.cluster.local/alerts
     - name: roost-watchdog
       webhook_configs:
         - url: http://alert-bridge.roost.svc.cluster.local/watchdog
   ```

5. In the app, create a group and add the "Prometheus" contact (Group info → Add
   people). Every group Prometheus is in gets every alert. Until it is in one, the
   bridge reports failed deliveries (HTTP 409 from the chat server), so
   Alertmanager retries and the problem is visible.

The identity's name is `auth.AlertDisplayName` and its picture is
`server/internal/alertbridge/avatar.png` (offered on every start, and skipped
when unchanged). Changing either means rebuilding the images and restarting the
chat server (name) or the bridge (picture).

## Cluster notes

- Use a replicated StorageClass (Longhorn here) on a multi-node cluster. The
  default `local-path` ties a volume to the node the pod first landed on.
- Pods should run non-root with all capabilities dropped, no privilege
  escalation and the `RuntimeDefault` seccomp profile, and without a mounted
  service-account token (nothing here calls the Kubernetes API). Postgres runs
  as uid/gid 999 with `fsGroup: 999`.
- Default-deny ingress with explicit allows: only chat-server may reach
  Postgres and SeaweedFS. **NetworkPolicy does nothing unless the CNI enforces
  it.** k3s's default Flannel does not.
- chat-server ↔ Postgres is currently `sslmode=disable`, because the stock
  image has no TLS configured. Worth fixing once policy enforcement is
  confirmed.
- Migrating from MinIO means a fresh, empty bucket (the on-disk formats differ).
  Copy existing media out over the S3 API first.
