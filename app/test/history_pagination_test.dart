import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/demo/demo_json.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

/// Pages history like the real server: newest first, before/limit honored.
class _PagedApiClient extends FakeApiClient {
  _PagedApiClient(int count) : super(FakeWsClient()) {
    contacts = const [ApiContact(id: 'mom', displayName: 'Mom', online: true)];
    rooms = [
      ApiRoom(id: 'room-1', isGroup: false, createdBy: 'mom', createdAt: _start, members: const ['me', 'mom']),
    ];
    messagesByRoom['room-1'] = [
      for (var i = 0; i < count; i++)
        ApiMessage(
          id: 'm$i',
          roomId: 'room-1',
          senderId: i.isEven ? 'mom' : 'me',
          kind: 'text',
          body: 'Message number $i',
          createdAt: _start.add(Duration(minutes: i)),
        ),
    ];
  }

  static final _start = DateTime.now().subtract(const Duration(days: 1));

  final List<DateTime?> pageRequests = [];

  /// When set, page requests wait for it (to look at the loading state).
  Completer<void>? gate;

  /// When set, the next page request fails.
  bool failNext = false;

  @override
  Future<List<ApiMessage>> listMessages(String roomId, {DateTime? before, int limit = 50}) async {
    pageRequests.add(before);
    if (gate != null) await gate!.future;
    if (failNext) {
      failNext = false;
      throw Exception('offline');
    }
    final all = [...messagesByRoom[roomId] ?? const <ApiMessage>[]]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.where((m) => before == null || m.createdAt.isBefore(before)).take(limit).toList();
  }
}

void main() {
  group('MessagesController paging', () {
    late _PagedApiClient api;
    late ProviderContainer container;

    setUp(() {
      api = _PagedApiClient(120);
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ]);
      addTearDown(container.dispose);
    });

    List<String> ids() => [for (final m in container.read(messagesProvider('room-1')).value!) m.id];

    test('opens with the newest page, then loads older pages until the start of the chat', () async {
      await container.read(messagesProvider('room-1').future);
      final controller = container.read(messagesProvider('room-1').notifier);
      expect(ids(), [for (var i = 70; i < 120; i++) 'm$i'], reason: 'newest 50, oldest first');
      expect(controller.hasOlder, isTrue);

      await controller.loadOlder();
      expect(ids(), [for (var i = 20; i < 120; i++) 'm$i']);

      await controller.loadOlder();
      expect(ids(), [for (var i = 0; i < 120; i++) 'm$i']);
      expect(controller.hasOlder, isFalse, reason: 'a short page means the start was reached');

      final requests = api.pageRequests.length;
      await controller.loadOlder();
      expect(api.pageRequests, hasLength(requests), reason: 'nothing more to ask for');
    });

    test('a chat shorter than a page never asks for more', () async {
      api = _PagedApiClient(12);
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ]);
      addTearDown(container.dispose);
      await container.read(messagesProvider('room-1').future);

      await container.read(messagesProvider('room-1').notifier).loadOlder();

      expect(api.pageRequests, [null]);
    });

    test('scrolling while a page loads asks for it once, and shows it loading', () async {
      await container.read(messagesProvider('room-1').future);
      final controller = container.read(messagesProvider('room-1').notifier);
      api.gate = Completer<void>();

      final first = controller.loadOlder();
      final second = controller.loadOlder();
      expect(container.read(loadingOlderMessagesProvider('room-1')), isTrue);

      api.gate!.complete();
      await Future.wait([first, second]);
      expect(api.pageRequests, hasLength(2), reason: 'the initial page plus one older page');
      expect(container.read(loadingOlderMessagesProvider('room-1')), isFalse);
    });

    test('a failed page changes nothing and is retried next time', () async {
      await container.read(messagesProvider('room-1').future);
      final controller = container.read(messagesProvider('room-1').notifier);

      api.failNext = true;
      await controller.loadOlder();
      expect(ids(), hasLength(50));
      expect(container.read(loadingOlderMessagesProvider('room-1')), isFalse);

      await controller.loadOlder();
      expect(ids(), hasLength(100));
    });

    test('a message arriving while an older page loads is kept', () async {
      await container.read(messagesProvider('room-1').future);
      final controller = container.read(messagesProvider('room-1').notifier);
      api.gate = Completer<void>();

      final loading = controller.loadOlder();
      final live = ApiMessage(
          id: 'live', roomId: 'room-1', senderId: 'mom', kind: 'text', body: 'hi', createdAt: DateTime.now());
      api.ws.emit(WsEvent('message.created', messageToJson(live)));
      await Future<void>.delayed(Duration.zero);
      api.gate!.complete();
      await loading;

      expect(ids().first, 'm20');
      expect(ids().last, 'live');
      expect(ids(), hasLength(101));
    });
  });

  testWidgets('scrolling back through a long chat keeps loading older messages, down to the first one',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    appRouter.go('/');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _PagedApiClient(120);
    await tester.pumpWidget(RoostRoot(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsClientProvider.overrideWithValue(api.ws),
      imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mom').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Message number 119'), findsOneWidget);

    final first = find.textContaining('Message number 0', skipOffstage: false);
    for (var i = 0; i < 80 && first.evaluate().isEmpty; i++) {
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 600), 2000);
      await tester.pumpAndSettle();
    }

    expect(first, findsOneWidget, reason: 'the very first message was reached');
    expect(api.pageRequests, hasLength(3), reason: 'three pages of 50: 120 messages');
    expect(find.byKey(const ValueKey('loading-older-messages')), findsNothing);
  });
}
