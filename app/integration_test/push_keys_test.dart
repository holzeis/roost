import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// FR5.2 on a real iOS device or simulator: the app creates its key pair
/// for encrypted notification previews in the keychain group it shares with
/// the notification service extension (ios/Shared/PushKeyStore.swift), and
/// keeps returning the same public key. Run with:
///
///   flutter test integration_test/push_keys_test.dart -d <ios-device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the push key is created once in the shared keychain and reused', (tester) async {
    const channel = MethodChannel('roost/push_keys');
    final first = await channel.invokeMethod<String>('publicKey');
    final again = await channel.invokeMethod<String>('publicKey');

    expect(first, isNotNull);
    expect(base64Decode(first!), hasLength(32), reason: 'an X25519 public key');
    expect(again, first, reason: 'stored, not regenerated');
  });

  testWidgets('the server address goes along for the extension, without changing the key', (tester) async {
    const channel = MethodChannel('roost/push_keys');
    final before = await channel.invokeMethod<String>('publicKey');
    final after = await channel.invokeMethod<String>('publicKey', {'apiBaseUrl': 'http://roost-chat'});
    final bad = await channel.invokeMethod<String>('publicKey', {'apiBaseUrl': 'file:///etc'});

    expect(after, before);
    expect(bad, before, reason: 'an unusable address is ignored, not an error');
  });
}
