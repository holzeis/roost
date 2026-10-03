import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/api_config.dart' as config;
import 'data/api_models.dart';
import 'demo/demo_banner.dart';
import 'demo/demo_mode.dart';
import 'providers/chat_providers.dart';
import 'router/app_router.dart';
import 'services/push_service.dart';
import 'services/share_intake.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  // Required before any plugin call — both firebase_messaging and
  // flutter_callkit_incoming (see PushService) need the binding attached
  // before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(RoostRoot(initialDemo: await loadDemoMode()));
}

/// Whether the app was left in demo mode last time — read before the first
/// frame so a reviewer relaunching the app lands straight back in the demo
/// instead of flashing the "can't reach the server" screen first.
Future<bool> loadDemoMode({bool available = config.demoAvailable}) async {
  if (!available) return false;
  try {
    return (await SharedPreferences.getInstance()).getBool(demoModePrefKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// Owns the one app-wide ProviderScope and whether it's pointed at the
/// family's real server or the in-app demo (lib/demo/). Switching rebuilds
/// the scope from scratch under a new key, so nothing — cached messages, the
/// WebSocket, the demo's own data — ever carries over between the two.
class RoostRoot extends StatefulWidget {
  const RoostRoot({
    super.key,
    this.initialDemo = false,
    this.demoAvailable = config.demoAvailable,
    this.overrides = const [],
    this.demoOverrides = const [],
  });

  final bool initialDemo;
  final bool demoAvailable;

  /// Extra provider overrides outside / inside demo mode (tests only).
  final List<Override> overrides;
  final List<Override> demoOverrides;

  @override
  State<RoostRoot> createState() => _RoostRootState();
}

class _RoostRootState extends State<RoostRoot> {
  late bool _demo = widget.initialDemo && widget.demoAvailable;

  Future<void> _setDemo(bool enabled) async {
    if (enabled && !widget.demoAvailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(demoModePrefKey, enabled);
    } catch (_) {
      // Best-effort: the switch still happens, it just won't survive a relaunch.
    }
    appRouter.go('/');
    if (mounted) setState(() => _demo = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: ValueKey(_demo),
      overrides: [
        ...(_demo ? widget.demoOverrides : widget.overrides),
        demoAvailableProvider.overrideWithValue(widget.demoAvailable),
        demoModeProvider.overrideWithValue(DemoMode(enabled: _demo, setEnabled: _setDemo)),
      ],
      child: const RoostApp(),
    );
  }
}

class RoostApp extends ConsumerStatefulWidget {
  const RoostApp({super.key});

  @override
  ConsumerState<RoostApp> createState() => _RoostAppState();
}

class _RoostAppState extends ConsumerState<RoostApp> {
  // Coming back to the foreground: iOS may have silently killed the socket
  // while the app was suspended, and messages sent meanwhile went out as
  // push notifications instead — reconnect now, which also makes every
  // open chat catch up (see WsClient.connectedEvent).
  late final AppLifecycleListener _lifecycle;

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.read(wsClientProvider).reconnectNow());
    // FR3.3: keep this user's live location shares live across a restart.
    ref.read(locationShareResumerProvider);
    // FR2.7: photos/videos shared into Roost from other apps.
    unawaited(ref.read(shareIntakeProvider).start());
    // FR5.1: registers this device for push-woken incoming calls and wires
    // up CallKit accept/decline — a one-time app-startup side effect, not
    // tied to any particular screen's lifecycle. Skipped in the demo, which
    // has no server to push anything and shouldn't prompt for notification
    // permission.
    if (!ref.read(demoModeProvider).enabled) {
      final push = ref.read(pushServiceProvider);
      unawaited(push.init());
      // Notification permission is only asked for once the server answers
      // (see PushService.serverReached) — never on the "can't reach the
      // server" screen, or in a demo entered from it.
      ref.listenManual<AsyncValue<ApiUser>>(meProvider, (_, me) {
        if (me.hasValue && !ref.read(demoModeProvider).enabled) push.serverReached();
      }, fireImmediately: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final demo = ref.watch(demoModeProvider).enabled;

    // FR4.4 (foreground/backgrounded case): an incoming call has to
    // interrupt whatever screen is open, so this listens app-wide rather
    // than from within any particular screen — see incomingCallProvider's
    // doc comment in providers/chat_providers.dart. appRouter is pushed
    // directly (it's a module-level singleton) since there's no single
    // BuildContext that's always valid here.
    ref.listen<IncomingCallInfo?>(incomingCallProvider, (previous, next) {
      if (next != null) {
        appRouter.push('/call/${next.roomId}/incoming?messageId=${next.messageId}');
      }
    });

    return MaterialApp.router(
      title: 'Roost',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
      builder: demo ? (context, child) => DemoBanner(child: child ?? const SizedBox.shrink()) : null,
    );
  }
}
