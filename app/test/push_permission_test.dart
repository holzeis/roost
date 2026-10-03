import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/demo/demo_mode.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

/// A server that can be switched off, like the family's server seen from
/// outside the tailnet (or by an App Store reviewer).
class _MaybeOfflineApi extends FakeApiClient {
  _MaybeOfflineApi({required this.online}) : super(FakeWsClient());

  bool online;

  @override
  Future<ApiUser> getMe() async {
    if (!online) throw Exception('Could not reach the chat server');
    return super.getMe();
  }
}

void main() {
  const callKit = MethodChannel('flutter_callkit_incoming');
  final asked = <String>[];

  setUp(() {
    asked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(callKit, (call) async {
      if (call.method == 'requestNotificationPermission') asked.add(call.method);
      if (call.method == 'activeCalls') return <dynamic>[];
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(callKit, null));

  Future<ProviderContainer> pump(WidgetTester tester, FakeApiClient api, {bool demo = false}) async {
    appRouter.go('/');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
        if (demo) demoModeProvider.overrideWithValue(DemoMode(enabled: true, setEnabled: (_) async {})),
      ],
      child: const RoostApp(),
    ));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(RoostApp)));
  }

  group('notification permission', () {
    testWidgets('is asked for once the server answers', (tester) async {
      await pump(tester, _MaybeOfflineApi(online: true));
      expect(asked, ['requestNotificationPermission']);
    });

    testWidgets('is not asked for while the server can\'t be reached, only once it can', (tester) async {
      final api = _MaybeOfflineApi(online: false);
      final container = await pump(tester, api);
      expect(find.textContaining('Could not reach'), findsWidgets, reason: 'the screen a reviewer starts on');
      expect(asked, isEmpty);

      api.online = true;
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      expect(asked, ['requestNotificationPermission']);
    });

    testWidgets('is never asked for in the demo', (tester) async {
      await pump(tester, _MaybeOfflineApi(online: true), demo: true);
      expect(asked, isEmpty);
    });
  });
}
