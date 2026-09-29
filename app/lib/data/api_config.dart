/// Where the chat server is. Overridable at build/run time:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
///
/// Defaults to localhost:8080, matching docker-compose.yml's chat-server
/// port mapping and docs/ios-dev-setup.md. The iOS Simulator shares the
/// host's network so `localhost` works directly; the Android emulator needs
/// `10.0.2.2` instead (its alias for the host loopback).
///
/// In production there's no equivalent of this constant to set per-build —
/// the app instead needs a way to point at the deployed tailnet hostname,
/// which will replace this once a settings/onboarding screen exists.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

/// Whether this build offers the in-app demo (lib/demo/) on the "can't reach
/// the server" screen — for App Store review, where the reviewer can't join
/// the family's tailnet. Off unless the build sets it:
///   flutter build ipa --dart-define=DEMO_AVAILABLE=true
/// Turning it off again is just a build without it (see release.yml).
const demoAvailable = bool.fromEnvironment('DEMO_AVAILABLE');

/// The same host, as a ws:// URL, for the /ws endpoint.
String get wsBaseUrl => apiBaseUrl.replaceFirst(RegExp(r'^http'), 'ws');

/// Where LiveKit is (FR4.*) — the chat server only mints a token; the app
/// connects to LiveKit's own SFU directly (see
/// docs/architecture-overview.md's "chat server brokers signaling, never
/// touches media"). Defaults to docker-compose.yml's LiveKit port mapping,
/// overridable the same way as [apiBaseUrl]:
///   flutter run --dart-define=LIVEKIT_URL=ws://10.0.2.2:7880
const livekitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'ws://localhost:7880',
);
