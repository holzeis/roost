import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
