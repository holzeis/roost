import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

/// Catching up on what arrived while the socket was down — e.g. a message
/// delivered as a push notification while the app was suspended.
void main() {
  final t0 = DateTime(2026, 9, 30, 12);
  ApiMessage msg(String id, int minute, {String body = 'hi', String senderId = 'them'}) => ApiMessage(
        id: id,
        roomId: 'room-1',
        senderId: senderId,
        kind: 'text',
        body: body,
        createdAt: t0.add(Duration(minutes: minute)),
      );
  List<String> ids(List<ApiMessage> list) => [for (final m in list) m.id];

  group('mergeLatestMessages', () {
    test('adds what arrived while away and replaces stale copies', () {
      final current = [msg('a', 1), msg('b', 2, body: 'old')];
      final latest = [msg('c', 3), msg('b', 2, body: 'edited'), msg('a', 1)]; // newest first
      final merged = mergeLatestMessages(current, latest, complete: true);
      expect(ids(merged), ['a', 'b', 'c']);
      expect(merged[1].body, 'edited');
    });

    test('drops a message deleted while away, but only within the fetched range', () {
      final current = [msg('old', 1), msg('a', 5), msg('gone', 6), msg('b', 7)];
      final latest = [msg('b', 7), msg('a', 5)];
      expect(ids(mergeLatestMessages(current, latest, complete: false)), ['old', 'a', 'b'],
          reason: '"old" is older than the page, so it just wasn\'t fetched');
      expect(ids(mergeLatestMessages(current, latest, complete: true)), ['a', 'b'],
          reason: 'a complete page covers the whole history');
    });

    test('keeps a message that arrived live while the fetch was in flight', () {
      final current = [msg('a', 1), msg('live', 9)];
      final latest = [msg('b', 2), msg('a', 1)];
      expect(ids(mergeLatestMessages(current, latest, complete: true)), ['a', 'b', 'live']);
    });

    test('an empty page leaves the list alone', () {
      final current = [msg('a', 1)];
      expect(mergeLatestMessages(current, const [], complete: true), same(current));
    });
  });

  group('MessagesController', () {
    test('catches up on (re)connect with what it missed, and acks it delivered', () async {
      final api = FakeApiClient(FakeWsClient());
      api.messagesByRoom['room-1'] = [msg('a', 1)];
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ]);
      addTearDown(container.dispose);
      await container.read(messagesProvider('room-1').future);

      // Arrives server-side while the socket is down: no message.created.
      api.messagesByRoom['room-1']!.add(msg('pushed', 2, body: 'sent while you were away'));
      expect(ids(container.read(messagesProvider('room-1')).value!), ['a']);

      api.ws.emit(const WsEvent(WsClient.connectedEvent, {}));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ids(container.read(messagesProvider('room-1')).value!), ['a', 'pushed']);
      final ack = api.receiptAcks.last;
      expect(ack.$1, 'room-1');
      expect(ack.$2, ['pushed']);
      expect(ack.$3, 'delivered');
    });
  });

  group('WsClient', () {
    test('announces every (re)connect, and a forced reconnect replaces the old socket cleanly', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var connections = 0;
      server.listen((request) async {
        connections++;
        await WebSocketTransformer.upgrade(request);
      });

      final client = WsClient(baseUrl: 'ws://127.0.0.1:${server.port}');
      addTearDown(client.dispose);
      final connected = <WsEvent>[];
      client.events.where((e) => e.type == WsClient.connectedEvent).listen(connected.add);

      client.connect();
      await _until(() => connected.length == 1);
      client.reconnectNow();
      await _until(() => connected.length == 2);
      expect(connections, 2);

      // The replaced socket closing must not schedule a reconnect of its
      // own (that would run 3s later).
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect(connections, 2);
      expect(connected, hasLength(2));
    });
  });

  testWidgets('returning to the foreground forces a fresh socket', (tester) async {
    appRouter.go('/');
    final api = FakeApiClient(FakeWsClient());
    await tester.pumpWidget(RoostRoot(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsClientProvider.overrideWithValue(api.ws),
      imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
    ]));
    await tester.pumpAndSettle();

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();

    expect(api.ws.reconnects, 1);
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
