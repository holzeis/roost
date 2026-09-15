import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/providers/chat_providers.dart';

import 'fakes.dart';

/// FR1.5/FR1.6: sent/delivered/seen status. These exercise the provider
/// logic directly (no widget tree) since the status/ack behavior lives in
/// MessagesController, not in the chat screen's rendering — the icon it
/// draws (chat_screen.dart's _statusIconSpan) is thin display logic on top
/// of message.status, verified manually per the feature's plan.
void main() {
  group('message delivery/seen status', () {
    late FakeApiClient api;
    late ProviderContainer container;

    setUp(() {
      api = FakeApiClient(FakeWsClient());
      api.messagesByRoom['room-1'] = [
        ApiMessage(
          id: 'm1',
          roomId: 'room-1',
          senderId: 'them',
          kind: 'text',
          body: 'hi',
          createdAt: DateTime.now(),
        ),
      ];
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ]);
      addTearDown(container.dispose);
    });

    test(
        'ApiMessage.fromJson defaults a missing status to sent and round-trips an explicit one',
        () {
      final withoutStatus = ApiMessage.fromJson({
        'id': 'm',
        'roomId': 'r',
        'senderId': 's',
        'kind': 'text',
        'createdAt': DateTime.now().toIso8601String(),
      });
      expect(withoutStatus.status, 'sent');

      final withStatus = ApiMessage.fromJson({
        'id': 'm',
        'roomId': 'r',
        'senderId': 's',
        'kind': 'text',
        'createdAt': DateTime.now().toIso8601String(),
        'status': 'seen',
      });
      expect(withStatus.status, 'seen');
    });

    test(
        'loading a room\'s history auto-acks messages from other senders as delivered',
        () async {
      await container.read(messagesProvider('room-1').future);
      await Future<void>.delayed(
          Duration.zero); // let the fire-and-forget ack land

      final ack = api.receiptAcks.single;
      expect(ack.$1, 'room-1');
      expect(ack.$2, ['m1']);
      expect(ack.$3, 'delivered');
    });

    test('loading history does not ack the caller\'s own messages', () async {
      api.messagesByRoom['room-1'] = [
        ApiMessage(
            id: 'mine',
            roomId: 'room-1',
            senderId: api.me.id,
            kind: 'text',
            body: 'x',
            createdAt: DateTime.now()),
      ];

      await container.read(messagesProvider('room-1').future);
      await Future<void>.delayed(Duration.zero);

      expect(api.receiptAcks, isEmpty);
    });

    test('a live message.created push is auto-acked as delivered too',
        () async {
      api.messagesByRoom['room-1'] = [];
      await container.read(messagesProvider('room-1').future);
      api.receiptAcks.clear();

      api.ws.emit(WsEvent('message.created', {
        'id': 'm2',
        'roomId': 'room-1',
        'senderId': 'them',
        'kind': 'text',
        'body': 'incoming',
        'createdAt': DateTime.now().toIso8601String(),
      }));
      await Future<void>.delayed(Duration.zero);

      final ack = api.receiptAcks.single;
      expect(ack.$1, 'room-1');
      expect(ack.$2, ['m2']);
      expect(ack.$3, 'delivered');
    });

    test('a message.status WS event updates the matching message in place',
        () async {
      await container.read(messagesProvider('room-1').future);

      api.ws.emit(const WsEvent('message.status',
          {'messageId': 'm1', 'roomId': 'room-1', 'status': 'seen'}));
      await Future<void>.delayed(Duration.zero);

      final messages = container.read(messagesProvider('room-1')).valueOrNull;
      expect(messages!.single.status, 'seen');
    });

    test('ackSeen only sends ids for other senders that aren\'t already seen',
        () async {
      api.messagesByRoom['room-1'] = [
        ApiMessage(
            id: 'm1',
            roomId: 'room-1',
            senderId: 'them',
            kind: 'text',
            body: 'a',
            createdAt: DateTime.now()),
        ApiMessage(
          id: 'm2',
          roomId: 'room-1',
          senderId: 'them',
          kind: 'text',
          body: 'b',
          createdAt: DateTime.now(),
          status: 'seen',
        ),
        ApiMessage(
            id: 'm3',
            roomId: 'room-1',
            senderId: api.me.id,
            kind: 'text',
            body: 'mine',
            createdAt: DateTime.now()),
      ];
      await container.read(messagesProvider('room-1').future);
      await Future<void>.delayed(
          Duration.zero); // let the initial delivered auto-ack settle first
      api.receiptAcks.clear();

      await container
          .read(messagesProvider('room-1').notifier)
          .ackSeen(['m1', 'm2', 'm3', 'does-not-exist']);

      final ack = api.receiptAcks.single;
      expect(ack.$1, 'room-1');
      expect(ack.$2, ['m1']);
      expect(ack.$3, 'seen');
    });
  });
}
