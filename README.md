# Roost

Self-hosted family chat, media sharing, and video calling — running on a
home Tailscale network with no open ports. See
[`docs/architecture-overview.md`](docs/architecture-overview.md) for the
full design and [`docs/functional-requirements.md`](docs/functional-requirements.md)
for scope.

## Layout

| Path | What |
|---|---|
| `server/` | The chat server (Go): REST API, WebSocket fan-out, LiveKit token minting, Tailscale identity resolution |
| `app/` | The Flutter mobile app (iOS + Android) |
| `docker-compose.yml` | Full local stack: Postgres, MinIO, LiveKit, chat server |
| `k8s/` | Deployment manifests/Helm values for the target k3s cluster |
| `docs/` | Architecture, functional requirements, data model, mockups |
| `.github/workflows/` | CI (build + test) and the app store release pipeline |

## Local development

```sh
cp .env.example .env   # fill in local passwords; never commit .env
docker compose up -d
```

This runs the whole backend — chat server, Postgres, MinIO, LiveKit — with
`ENABLE_DEV_AUTH=true`, which bypasses real Tailscale identity resolution
with a fixed dev identity (there's no tailnet to join from a laptop compose
stack). Never enable that outside local development; see
`server/internal/auth/dev_resolver.go`.

Then, for the app:

```sh
cd app
flutter pub get
flutter run
```

See [`docs/ios-dev-setup.md`](docs/ios-dev-setup.md) for iOS Simulator setup
specifics.

### Android build setup

Building for Android needs a **JDK 17** (Gradle 9.3.1 + AGP 9.1.0, as used
by `app/android/`, won't run under JDK 11; JDK 21+ needs a newer Gradle than
that). Flutter prioritizes Android Studio's own bundled JDK over `JAVA_HOME`
when picking which one to use, so setting `JAVA_HOME` alone often has no
effect — and `/usr/libexec/java_home` won't find a Homebrew JDK installed
keg-only (it silently falls back to another installed JVM instead of
failing, so don't rely on it here). Point Flutter at the JDK 17 install path
directly instead:

```sh
brew install openjdk@17
flutter config --jdk-dir=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
```

### Google Maps API keys

Live location sharing (FR3.*) renders maps via each platform's native Maps
SDK, which needs its own API key — get one per platform from
[Google Cloud Console](https://console.cloud.google.com/) (enable "Maps SDK
for Android" / "Maps SDK for iOS"), and never commit the real key anywhere:

- **Android**: add a line to `app/android/local.properties` (already
  gitignored, created for you by the Flutter tooling on first run):
  ```
  MAPS_API_KEY=your-android-key-here
  ```
- **iOS**: copy `app/ios/Runner/Config.xcconfig.example` to
  `app/ios/Runner/Config.xcconfig` (gitignored) and fill in
  `GOOGLE_MAPS_API_KEY`.

Without a real key, the app still builds and runs — maps just render blank
grey tiles instead of imagery.

## Testing

```sh
cd server && go test ./...                                    # unit tests
DATABASE_URL=postgres://roost:roost-dev-password@localhost:5432/roost?sslmode=disable \
  go test -tags=integration ./...                              # integration tests, needs `docker compose up -d postgres`

cd app && flutter analyze && flutter test
```

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for how work on this repo is expected to be
done — source-of-truth docs, testing bar, commit conventions.
