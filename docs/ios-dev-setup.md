# iOS Simulator development setup

How to run the Flutter app (`app/`) on an iOS Simulator for local
development. Keep this current as the setup changes.

## Prerequisites

1. **Xcode** — install from the Mac App Store, then accept the license and
   install the command-line tools:
   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```
2. **CocoaPods** — the dependency manager Flutter's iOS build uses for
   plugin native code:
   ```sh
   sudo gem install cocoapods
   ```
3. **Flutter SDK** — install per <https://docs.flutter.dev/get-started/install/macos>,
   then verify:
   ```sh
   flutter doctor
   ```
   Resolve anything it flags under "Xcode" or "CocoaPods" before continuing.

## First run

```sh
cd app
flutter pub get
open -a Simulator                 # boots the default simulator
flutter devices                   # confirm a simulator shows up
flutter run                       # builds and launches on the booted simulator
```

The first `flutter run` also runs `pod install` under `app/ios/` — if that
step fails, `cd app/ios && pod repo update && pod install` and retry.

## Choosing a specific simulator target

```sh
xcrun simctl list devices available   # find a device's UDID
flutter run -d <UDID>
```

CallKit's native incoming-call UI (FR4.4) is only meaningfully testable on a
real device — the Simulator can present the CallKit sheet, but there's no
real APNs delivery to a simulator, so wake-from-push flows need a physical
iPhone with a Tailscale connection and a development provisioning profile.
For local UI/chat/call-control development, the Simulator is sufficient.

## Testing location sharing (FR3.*)

The Simulator has no real GPS, but Xcode can feed it a simulated position:
with the app running, **Debug ▸ Location** in the Simulator menu bar (or a
custom GPX route) lets you start a share and watch position updates land.
That's enough to exercise the foreground flow — starting a share, seeing the
map bubble, ending it early, watching the TTL expire.

True background behavior (the location keeps updating while the app is
backgrounded/the phone is locked — see `docs/architecture-overview.md`'s
note on this) needs a real device with a granted "Always" location
permission: the Simulator doesn't meaningfully suspend/resume apps the way
a physical device does, so background delivery isn't a reliable signal
there. Same caveat as CallKit above — local UI development is fine on the
Simulator, but the behavior this feature is actually *for* needs a physical
iPhone.

See the root [`README.md`](../README.md#google-maps-api-keys) for setting up
a Maps API key — without one the map renders as blank grey tiles.

## Running on a real device standalone (not tethered to `flutter run`)

`flutter run` installs a **debug** build. Debug builds are JIT-compiled and
stay connected to the Dart VM Service on your Mac the whole time they run —
closing the app and reopening it from the home screen with no `flutter run`
attached leaves it with no way to fetch/execute its own Dart code, so it
exits immediately on launch. This is true of every Flutter app in debug
mode, on every platform — it isn't a bug in this app.

To get a build that opens from the home screen on its own, indefinitely,
install a **release** (or `--profile`) build instead — these are fully
AOT-compiled and don't need your Mac at all once installed:

```sh
flutter run --release -d <device-id>       # builds, installs, and launches
# or, to install without immediately launching:
flutter build ios --release
```

A few notes specific to this repo:

- The Xcode project already has a development team configured
  (`DEVELOPMENT_TEAM` in `ios/Runner.xcodeproj`, automatic signing) — a
  release build should sign and install without extra setup as long as
  that team/Apple ID is the one signed into Xcode.
- A **free** Apple ID (no paid Developer Program) can sign and install to
  your own registered devices this way, but the resulting build's
  provisioning profile expires after **7 days** — reinstall by rerunning
  the command above. The paid Program ($99/yr) removes that limit and is
  what `.github/workflows/release.yml` uses to ship to TestFlight instead.
- If `flutter run --release -d <device-id>` reports install succeeded but
  launch failed with a "device was not, or could not be, unlocked" error,
  the app is already installed — unlock the device and open it from the
  home screen manually.

## Talking to a local chat server

The Simulator runs on your Mac's network namespace, so `docker-compose.yml`'s
`chat-server` (bound to `127.0.0.1:8080`, `ENABLE_DEV_AUTH=true`) is reachable
directly — no tailnet needed for local development. Point the app at
`http://localhost:8080` (see `app/lib/data/` once the API client lands).

## Troubleshooting

- `flutter doctor` complaining about an unsigned/untrusted simulator runtime:
  open Xcode once and let it finish installing additional components.
  `xcodebuild -runFirstLaunch` again.
- Pod install failures after a Flutter upgrade: `cd app/ios && rm -rf Pods
  Podfile.lock && pod install`.
- Stale build cache after switching branches: `flutter clean && flutter pub
  get`.
