import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'providers/chat_providers.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The iOS Simulator can't bring up WebRTC's Voice-Processing I/O audio
  // unit — the one that does echo cancellation, and the default for calls.
  // AURemoteIO::Initialize times out talking to the audio daemon, and
  // AudioToolbox responds by calling abort(), so the app dies with SIGABRT
  // the moment a call starts. Bypassing voice processing falls back to the
  // plain RemoteIO unit, which the simulator does handle.
  //
  // Deliberately scoped to the simulator alone: on real hardware this would
  // disable hardware echo cancellation and make calls echo badly. Anywhere
  // else this call is skipped entirely, leaving WebRTC to initialize lazily
  // with its own defaults exactly as before.
  // Auto-detection reads the SIMULATOR_* variables the Simulator puts in the
  // process environment. That isn't guaranteed to be visible from Dart, so
  // --dart-define=BYPASS_VOICE_PROCESSING=true forces it on regardless.
  const bypassOverride = String.fromEnvironment('BYPASS_VOICE_PROCESSING');
  final isIosSimulator =
      Platform.isIOS && Platform.environment.keys.any((k) => k.startsWith('SIMULATOR_'));
  final bypassVoiceProcessing =
      bypassOverride.isEmpty ? isIosSimulator : bypassOverride == 'true';
  if (bypassVoiceProcessing) {
    await lk.LiveKitClient.initialize(bypassVoiceProcessing: true);
  }

  runApp(const ProviderScope(child: RoostApp()));
}

class RoostApp extends ConsumerWidget {
  const RoostApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

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
    );
  }
}
