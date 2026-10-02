import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The encryption scheme of message-notification previews (FR5.2) this app
/// understands — see server/internal/cryptobox, which is the reference: an
/// X25519 + HKDF-SHA256 + ChaCha20-Poly1305 "sealed box" to this device's
/// key. The same construction is implemented in Swift for the iOS
/// notification extension (ios/NotificationServiceExtension/); all three
/// are checked against server/internal/cryptobox/testdata/push_vector.json.
const pushCryptoScheme = 'v1';

const _domain = 'roost-push-v1';

/// Where Android keeps this device's private key (iOS keeps its key in
/// Swift, see ios/Shared/PushKeyStore.swift — Dart never sees it there).
const pushPrivateKeyStorageKey = 'messagePushPrivateKeyV1';

/// This device's push key pair on Android: created once, then kept in the
/// platform's secure storage. A new one after a reinstall is fine — the app
/// re-registers its public key on every start.
Future<SimpleKeyPair> loadOrCreateDeviceKeyPair(FlutterSecureStorage storage) async {
  final algorithm = X25519();
  final stored = await storage.read(key: pushPrivateKeyStorageKey);
  if (stored != null) {
    try {
      return await algorithm.newKeyPairFromSeed(base64Decode(stored));
    } catch (_) {
      // Unreadable: replace it below.
    }
  }
  final keyPair = await algorithm.newKeyPair();
  await storage.write(key: pushPrivateKeyStorageKey, value: base64Encode(await keyPair.extractPrivateKeyBytes()));
  return keyPair;
}

/// The base64 public key to register with the server.
Future<String> publicKeyBase64(SimpleKeyPair keyPair) async =>
    base64Encode((await keyPair.extractPublicKey()).bytes);

/// Decrypts a message notification's preview, or returns null if it can't
/// — no key, a payload from another scheme, a malformed or tampered one.
/// Never throws: the caller shows generic text instead, and this runs in a
/// background isolate where an exception would just lose the notification.
Future<String?> decryptPushPreview({
  required SimpleKeyPair deviceKeyPair,
  required String? scheme,
  required String? ephemeralPublicKey,
  required String? ciphertext,
}) async {
  if (scheme != pushCryptoScheme || ephemeralPublicKey == null || ciphertext == null) return null;
  try {
    final ephemeral = base64Decode(ephemeralPublicKey);
    final sealed = base64Decode(ciphertext);
    if (ephemeral.length != 32 || sealed.length < 16) return null;
    final devicePublic = (await deviceKeyPair.extractPublicKey()).bytes;

    final shared = await X25519().sharedSecretKey(
      keyPair: deviceKeyPair,
      remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519),
    );
    // HKDF-SHA256 with an empty salt (equivalent to the RFC's all-zero
    // salt) and info binding both public keys and the scheme's domain.
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: const <int>[],
      info: [...ephemeral, ...devicePublic, ...utf8.encode(_domain)],
    );
    final plain = await Chacha20.poly1305Aead().decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - 16),
        nonce: List<int>.filled(12, 0),
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: key,
    );
    return utf8.decode(plain);
  } catch (_) {
    return null;
  }
}

/// This device's public key for encrypted previews, to register with the
/// server — or null if it has none (then it gets the generic text). On iOS
/// the key pair lives in the keychain, owned by Swift (see
/// ios/Shared/PushKeyStore.swift), so the notification service extension
/// can decrypt; on Android it's created and kept here.
class DevicePushKeys {
  const DevicePushKeys();

  static const _channel = MethodChannel('roost/push_keys');

  /// Android's secure storage for the private key.
  static const storage = FlutterSecureStorage();

  Future<String?> publicKey() async {
    try {
      if (Platform.isIOS) return await _channel.invokeMethod<String>('publicKey');
      if (Platform.isAndroid) return await publicKeyBase64(await loadOrCreateDeviceKeyPair(storage));
    } catch (_) {
      // No usable key store: generic notification text it is.
    }
    return null;
  }
}

final devicePushKeysProvider = Provider<DevicePushKeys>((ref) => const DevicePushKeys());
