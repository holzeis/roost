import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_config.dart';
import 'demo_backend.dart';
import 'demo_cache_manager.dart';

/// The shared_preferences key remembering that the app is in demo mode, so a
/// relaunch (the reviewer closing and reopening the app) stays in the demo.
const demoModePrefKey = 'demoMode';

/// Whether this build offers the demo at all — [demoAvailable], a build
/// setting, by default. A provider rather than the bare constant only so
/// widget tests can turn it on.
final demoAvailableProvider = Provider<bool>((ref) => demoAvailable);

/// Whether the app is currently running against the in-app demo backend
/// (see demo_backend.dart) instead of the family's real server, plus the
/// switch to change that. Overridden by RoostRoot (lib/main.dart), which
/// rebuilds the whole ProviderScope on a switch so no state from one
/// backend ever leaks into the other.
class DemoMode {
  const DemoMode({required this.enabled, required this.setEnabled});

  final bool enabled;
  final Future<void> Function(bool enabled) setEnabled;
}

final demoModeProvider = Provider<DemoMode>(
  (ref) => DemoMode(enabled: false, setEnabled: (_) async {}),
);

/// The in-memory demo server — created (and seeded) on first use in demo
/// mode, discarded with everything the reviewer did when the demo is left.
final demoBackendProvider = Provider<DemoBackend>((ref) {
  final backend = DemoBackend();
  ref.onDispose(backend.dispose);
  return backend;
});

/// Serves the demo's images — see DemoCacheManager.
final demoCacheManagerProvider = Provider<DemoCacheManager>((ref) {
  final manager = DemoCacheManager(ref.watch(demoBackendProvider));
  ref.onDispose(manager.dispose);
  return manager;
});
