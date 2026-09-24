import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/chat_providers.dart';
import 'router/app_router.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

void main() {
  // Required before any plugin call — both firebase_messaging and
  // flutter_callkit_incoming (see PushService) need the binding attached
  // before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: RoostApp()));
}

class RoostApp extends ConsumerStatefulWidget {
  const RoostApp({super.key});

  @override
  ConsumerState<RoostApp> createState() => _RoostAppState();
}

class _RoostAppState extends ConsumerState<RoostApp> {
  @override
  void initState() {
    super.initState();
    // FR5.1: registers this device for push-woken incoming calls and wires
    // up CallKit accept/decline — a one-time app-startup side effect, not
    // tied to any particular screen's lifecycle.
    unawaited(ref.read(pushServiceProvider).init());
  }

  @override
  Widget build(BuildContext context) {
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
