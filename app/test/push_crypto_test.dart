import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/services/push_crypto.dart';

import 'fakes.dart';

/// The server's known-answer vector — the same file the Go tests (and the
/// iOS extension's Swift check) use, so all three implementations agree.
Map<String, dynamic> loadVector() =>
    jsonDecode(File('../server/internal/cryptobox/testdata/push_vector.json').readAsStringSync())
        as Map<String, dynamic>;

Future<SimpleKeyPair> vectorKeyPair(Map<String, dynamic> v) =>
    X25519().newKeyPairFromSeed(base64Decode(v['recipientPrivateKey'] as String));

void main() {
  test('decrypts the shared known-answer vector', () async {
    final v = loadVector();
    expect(v['scheme'], pushCryptoScheme);
    final keyPair = await vectorKeyPair(v);
    expect(await publicKeyBase64(keyPair), v['recipientPublicKey'], reason: 'same key derivation as Go');

    final preview = await decryptPushPreview(
      deviceKeyPair: keyPair,
      scheme: v['scheme'] as String,
      ephemeralPublicKey: v['ephemeralPublicKey'] as String,
      ciphertext: v['ciphertext'] as String,
    );
    expect(preview, v['plaintext']);
  });

  group('never throws, returns null when it can\'t decrypt', () {
    late Map<String, dynamic> v;
    late SimpleKeyPair keyPair;
    setUp(() async {
      v = loadVector();
      keyPair = await vectorKeyPair(v);
    });

    Future<String?> decrypt({String? scheme = 'v1', String? ephemeral, String? ciphertext, SimpleKeyPair? key}) =>
        decryptPushPreview(
          deviceKeyPair: key ?? keyPair,
          scheme: scheme,
          ephemeralPublicKey: ephemeral ?? v['ephemeralPublicKey'] as String,
          ciphertext: ciphertext ?? v['ciphertext'] as String,
        );

    test('a tampered ciphertext', () async {
      final bytes = base64Decode(v['ciphertext'] as String)..[0] ^= 1;
      expect(await decrypt(ciphertext: base64Encode(bytes)), isNull);
    });

    test('another device\'s key', () async {
      expect(await decrypt(key: await X25519().newKeyPair()), isNull);
    });

    test('an unknown scheme, or a payload without the encrypted fields', () async {
      expect(await decrypt(scheme: 'v2'), isNull);
      expect(await decrypt(scheme: null), isNull);
      expect(
          await decryptPushPreview(deviceKeyPair: keyPair, scheme: 'v1', ephemeralPublicKey: null, ciphertext: null),
          isNull);
    });

    test('garbage', () async {
      expect(await decrypt(ciphertext: 'not base64!'), isNull);
      expect(await decrypt(ephemeral: base64Encode([1, 2, 3])), isNull);
      expect(await decrypt(ciphertext: base64Encode([1, 2])), isNull);
    });
  });

  group('the device key pair (Android)', () {
    test('is created once and then reused', () async {
      final storage = FakeSecureStorage();
      final first = await loadOrCreateDeviceKeyPair(storage);
      final again = await loadOrCreateDeviceKeyPair(storage);
      expect(await publicKeyBase64(again), await publicKeyBase64(first));
      expect(storage.values.keys, [pushPrivateKeyStorageKey]);
    });

    test('an unreadable stored key is replaced', () async {
      final storage = FakeSecureStorage()..values[pushPrivateKeyStorageKey] = 'garbage';
      final keyPair = await loadOrCreateDeviceKeyPair(storage);
      expect(base64Decode(storage.values[pushPrivateKeyStorageKey]!), await keyPair.extractPrivateKeyBytes());
    });
  });
}
