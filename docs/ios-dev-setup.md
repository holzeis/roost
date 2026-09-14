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
