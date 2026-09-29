import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/chat/media_viewer_screen.dart';
import 'package:roost/features/chat/reply_preview.dart';
import 'package:roost/providers/chat_providers.dart';

import 'fakes.dart';

/// FR1.15: a message deleted after someone saw it stays as a placeholder.
void main() {
  ApiMessage message({String id = 'm1', String kind = 'text', String? body = 'hi', DateTime? deletedAt}) => ApiMessage(
        id: id,
        roomId: 'room-1',
        senderId: 'me',
        kind: kind,
        body: body,
        createdAt: DateTime.now(),
        deletedAt: deletedAt,
      );

  test('ApiMessage.fromJson reads deletedAt, and a message without it is not deleted', () {
    final deletedAt = DateTime.now();
    final json = {
      'id': 'm1',
      'roomId': 'room-1',
      'senderId': 'me',
      'kind': 'text',
      'createdAt': DateTime.now().toIso8601String(),
    };
    expect(ApiMessage.fromJson(json).isDeleted, isFalse);

    final deleted = ApiMessage.fromJson({...json, 'deletedAt': deletedAt.toIso8601String()});
    expect(deleted.isDeleted, isTrue);
    expect(deleted.deletedAt, deletedAt);
    expect(deleted.copyWith(status: 'seen').isDeleted, isTrue, reason: 'copyWith keeps deletedAt');
  });

  test('a deleted message, or a quote of one, previews as "Deleted message"', () {
    expect(messagePreviewLabel(message(body: null, deletedAt: DateTime.now())), deletedMessageLabel);
    expect(messagePreviewLabel(message(kind: 'deleted', body: null)), deletedMessageLabel);
    expect(messagePreviewLabel(message()), 'hi');
  });

  test('the media gallery skips a deleted photo', () {
    final photo = message(id: 'p1', kind: 'image', body: null);
    final deletedPhoto = message(id: 'p2', kind: 'image', body: null, deletedAt: DateTime.now());
    expect(mediaMessagesIn([photo, deletedPhoto, message()]).map((m) => m.id), ['p1']);
  });

  test('a message.updated carrying deletedAt turns the loaded message into a placeholder in place', () async {
    final api = FakeApiClient(FakeWsClient());
    api.messagesByRoom['room-1'] = [message(id: 'm1'), message(id: 'm2', body: 'later')];
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsClientProvider.overrideWithValue(api.ws),
    ]);
    addTearDown(container.dispose);
    final before = (await container.read(messagesProvider('room-1').future)).map((m) => m.id).toList();

    final placeholder = {
      'id': 'm1',
      'roomId': 'room-1',
      'senderId': 'me',
      'kind': 'text',
      'createdAt': DateTime.now().toIso8601String(),
      'deletedAt': DateTime.now().toIso8601String(),
    };
    api.ws.emit(WsEvent('message.updated', jsonDecode(jsonEncode(placeholder)) as Map<String, dynamic>));
    await Future<void>.delayed(Duration.zero);

    final messages = container.read(messagesProvider('room-1')).value!;
    expect(messages.map((m) => m.id), before, reason: 'it keeps its place in the list');
    final m1 = messages.firstWhere((m) => m.id == 'm1');
    expect(m1.isDeleted, isTrue);
    expect(m1.body, isNull);
    expect(messages.firstWhere((m) => m.id == 'm2').isDeleted, isFalse);
  });
}
