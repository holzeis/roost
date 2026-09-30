import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'package:roost/data/api_client.dart';
import 'package:roost/data/api_models.dart';
import 'package:roost/features/chat/chat_screen.dart';
import 'package:roost/features/home/home_screen.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

/// A call that takes a moment to start on the server.
class _SlowCallApiClient extends FakeApiClient {
  _SlowCallApiClient() : super(FakeWsClient());

  final pending = Completer<ApiMessage>();
  int startCalls = 0;

  @override
  Future<ApiMessage> startCall(String roomId) {
    startCalls++;
    return pending.future;
  }
}

/// Never the same chat stacked twice: "back" from a chat must reach Home.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeApiClient> pumpHome(WidgetTester tester, {FakeApiClient? client}) async {
    appRouter.go('/');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = (client ?? FakeApiClient(FakeWsClient()))
      ..contacts = const [ApiContact(id: 'mom', displayName: 'Mom', online: true)]
      ..rooms = [
        ApiRoom(
            id: 'room-1',
            isGroup: false,
            createdBy: 'mom',
            createdAt: DateTime.now(),
            members: const ['me', 'mom'],
            lastMessageBody: 'hello',
            lastMessageKind: 'text',
            lastMessageAt: DateTime.now()),
      ];
    api.messagesByRoom['room-1'] = [
      ApiMessage(id: 'm1', roomId: 'room-1', senderId: 'mom', kind: 'text', body: 'hello', createdAt: DateTime.now()),
    ];
    await tester.pumpWidget(RoostRoot(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsClientProvider.overrideWithValue(api.ws),
      imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
    ]));
    await tester.pumpAndSettle();
    return api;
  }

  int chatScreens() => find.byType(ChatScreen, skipOffstage: false).evaluate().length;

  testWidgets('a quick double tap on a chat opens it once', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.text('Mom'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.text('Mom'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(chatScreens(), 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(chatScreens(), 0);
  });

  testWidgets('tapping call again while the call is still starting starts it only once', (tester) async {
    final api = _SlowCallApiClient();
    await pumpHome(tester, client: api);
    await tester.tap(find.text('Mom'));
    await tester.pumpAndSettle();

    final callButton = find.widgetWithIcon(IconButton, TablerIcons.video).first;
    await tester.tap(callButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(callButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.startCalls, 1);

    // Let the start fail rather than open the real call screen (LiveKit
    // isn't available under test): the button works again afterwards.
    api.pending.completeError(ApiException(503, 'unreachable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not start call'), findsOneWidget);
    expect(chatScreens(), 1);
  });

  testWidgets("the router reports an opened chat as the screen on top (what NotificationOpener compares)",
      (tester) async {
    await pumpHome(tester);
    expect(appRouter.state.uri.path, '/');

    await tester.tap(find.text('Mom'));
    await tester.pumpAndSettle();

    expect(appRouter.state.uri.path, '/chat/room-1');
    expect(appRouter.routerDelegate.currentConfiguration.uri.path, '/',
        reason: 'the base location stays "/" — why it was the wrong thing to compare');
  });
}
