import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:roost/providers/chat_providers.dart';
import 'package:roost/services/message_notifications.dart';
import 'package:roost/services/push_crypto.dart';
import 'package:roost/services/push_service.dart';

import 'fakes.dart';

class _FakePushKeys implements DevicePushKeys {
  const _FakePushKeys(this.key);
  final String? key;

  @override
  Future<String?> publicKey() async => key;
}

/// Records what would be shown, instead of showing it.
class _RecordingPlugin implements FlutterLocalNotificationsPlugin {
  final shown = <({int id, String? title, String? body, NotificationDetails? details, String? payload})>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async =>
      shown.add((id: id, title: title, body: body, details: notificationDetails, payload: payload));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _avatarId = '0b7d3c1e-5f2a-4c4e-9d1b-2a3f4e5d6c7b';

void main() {
  // An encrypted message notification as the server sends it to Android,
  // using the shared known-answer vector.
  final v = jsonDecode(File('../server/internal/cryptobox/testdata/push_vector.json').readAsStringSync())
      as Map<String, dynamic>;
  final data = <String, dynamic>{
    'type': 'message',
    'roomId': 'room-1',
    'messageId': 'msg-1',
    'senderName': 'Mom',
    'scheme': v['scheme'],
    'ephemeralPublicKey': v['ephemeralPublicKey'],
    'ciphertext': v['ciphertext'],
  };
  Future<SimpleKeyPair> deviceKey() => X25519().newKeyPairFromSeed(base64Decode(v['recipientPrivateKey'] as String));

  group('telling pushes apart', () {
    test('a data-only message notification is shown by the app, and is not a call', () {
      final message = RemoteMessage(data: data);
      expect(isAppShownMessageNotification(message), isTrue);
      expect(isCallWakeMessage(message), isFalse);
    });

    test('call wake is still call wake', () {
      const message = RemoteMessage(data: {'roomId': 'room-1', 'messageId': 'msg-1', 'callId': 'c'});
      expect(isCallWakeMessage(message), isTrue);
      expect(isAppShownMessageNotification(message), isFalse);
    });

    test('a notification the OS shows (iOS, or no key) is left to the OS', () {
      const message = RemoteMessage(
        notification: RemoteNotification(title: 'Mom', body: 'New message'),
        data: {'type': 'message', 'roomId': 'room-1'},
      );
      expect(isAppShownMessageNotification(message), isFalse);
      expect(isCallWakeMessage(message), isFalse);
    });
  });

  group('messageNotificationContent', () {
    test('shows the sender and the decrypted preview', () async {
      final content = (await messageNotificationContent(data, keyPair: await deviceKey()))!;
      expect(content.title, 'Mom');
      expect(content.body, v['plaintext']);
      expect(content.roomId, 'room-1');
    });

    test('falls back to the generic text without a key, or with the wrong one', () async {
      expect((await messageNotificationContent(data, keyPair: null))!.body, genericMessageBody);
      expect((await messageNotificationContent(data, keyPair: await X25519().newKeyPair()))!.body, genericMessageBody);
    });

    test('names the sender and their picture, when they have one', () async {
      final content = (await messageNotificationContent(
          {...data, 'senderId': 'mom-id', 'senderAvatarMediaId': _avatarId}, keyPair: null))!;
      expect(content.senderId, 'mom-id');
      expect(content.senderAvatarMediaId, _avatarId);

      final without = (await messageNotificationContent({...data, 'senderAvatarMediaId': ''}, keyPair: null))!;
      expect(without.senderAvatarMediaId, isNull);
    });

    test('ignores anything that is not a message notification for a chat', () async {
      expect(await messageNotificationContent({...data, 'type': 'call'}, keyPair: null), isNull);
      expect(await messageNotificationContent({...data}..remove('roomId'), keyPair: null), isNull);
    });
  });

  group('storedDeviceKeyPair', () {
    test('reads the key the app created, and never creates one itself', () async {
      final storage = FakeSecureStorage();
      expect(await storedDeviceKeyPair(storage), isNull);
      expect(storage.values, isEmpty, reason: 'a push must not replace the registered key');

      final created = await loadOrCreateDeviceKeyPair(storage);
      final read = (await storedDeviceKeyPair(storage))!;
      expect(await publicKeyBase64(read), await publicKeyBase64(created));
    });
  });

  group('device registration', () {
    test('sends the public key with the message-notification token, not with call wake', () async {
      final api = FakeApiClient(FakeWsClient());
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        devicePushKeysProvider.overrideWithValue(const _FakePushKeys('PUBLIC-KEY')),
      ]);
      addTearDown(container.dispose);
      final service = container.read(pushServiceProvider);

      await service.registerDevice('ios', 'fcm-token', 'fcm');
      await service.registerDevice('ios', 'voip-token', 'voip');

      expect(api.registeredDevices.map((d) => (d.tokenType, d.pushPublicKey)), [
        ('fcm', 'PUBLIC-KEY'),
        ('voip', null),
      ]);
    });

    test('a device without a usable key still registers, for the generic text', () async {
      final api = FakeApiClient(FakeWsClient());
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        devicePushKeysProvider.overrideWithValue(const _FakePushKeys(null)),
      ]);
      addTearDown(container.dispose);

      await container.read(pushServiceProvider).registerDevice('android', 'fcm-token', 'fcm');

      expect(api.registeredDevices.single.pushPublicKey, isNull);
    });
  });

  group('the sender\'s picture', () {
    test('is fetched as the small preview from the chat server', () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return http.Response.bytes([1, 2, 3], 200);
      });
      expect(await fetchSenderAvatar(_avatarId, client: client, baseUrl: 'http://roost-chat'), [1, 2, 3]);
      expect(requested.single.toString(), 'http://roost-chat/api/media/$_avatarId?variant=preview');
    });

    test('is left out when the server can\'t give it, and never throws', () async {
      final notFound = MockClient((_) async => http.Response('', 404));
      final empty = MockClient((_) async => http.Response.bytes([], 200));
      final offline = MockClient((_) async => throw http.ClientException('offline'));
      for (final client in [notFound, empty, offline]) {
        expect(await fetchSenderAvatar(_avatarId, client: client), isNull);
      }
    });

    test('never asks for anything but a media id', () async {
      var asked = false;
      final client = MockClient((_) async {
        asked = true;
        return http.Response.bytes([1], 200);
      });
      for (final id in ['../users', 'x?variant=original', '']) {
        expect(await fetchSenderAvatar(id, client: client), isNull);
      }
      expect(asked, isFalse);
    });

    test('is shown on the notification as the sender\'s icon', () async {
      final plugin = _RecordingPlugin();
      final loaded = <String>[];
      await showMessageNotification(
        plugin,
        {...data, 'senderId': 'mom-id', 'senderAvatarMediaId': _avatarId},
        keyPair: await deviceKey(),
        loadAvatar: (id) async {
          loaded.add(id);
          return Uint8List.fromList([9, 9, 9]);
        },
      );

      expect(loaded, [_avatarId]);
      final shown = plugin.shown.single;
      expect((shown.title, shown.body, shown.payload), ('Mom', v['plaintext'], 'room-1'));
      final android = shown.details!.android!;
      expect(android.channelId, messagesChannel.channelId, reason: 'still the messages channel');
      expect((android.largeIcon! as ByteArrayAndroidBitmap).data, [9, 9, 9]);
      final style = android.styleInformation! as MessagingStyleInformation;
      final message = style.messages!.single;
      expect(message.text, v['plaintext']);
      expect(message.person!.name, 'Mom');
      expect(message.person!.key, 'mom-id');
      expect((message.person!.icon! as ByteArrayAndroidIcon).data, [9, 9, 9]);
    });

    test('without one, the notification is shown as before', () async {
      for (final (payload, loader) in <(Map<String, dynamic>, SenderAvatarLoader)>[
        (data, (_) async => fail('nothing to load')),
        ({...data, 'senderAvatarMediaId': _avatarId}, (_) async => null),
      ]) {
        final plugin = _RecordingPlugin();
        await showMessageNotification(plugin, payload, keyPair: await deviceKey(), loadAvatar: loader);
        final android = plugin.shown.single.details!.android!;
        expect(android.largeIcon, isNull);
        expect(android.styleInformation, isNull);
        expect(plugin.shown.single.body, v['plaintext']);
      }
    });
  });
}
