import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/chat_providers.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

void main() {
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
