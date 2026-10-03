import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// iOS's own emoji keyboard for reactions (ios/Runner/EmojiKeyboard.swift),
/// on a simulator or device. Typing an emoji can't be driven from here;
/// that path is covered by ios/RunnerTests/EmojiKeyboardTests.swift. Run
/// with:
///
///   flutter test integration_test/emoji_keyboard_test.dart -d <ios-device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('roost/emoji_keyboard');

  testWidgets('the emoji keyboard opens, and cancelling it picks nothing', (tester) async {
    expect(await channel.invokeMethod<bool>('isAvailable'), isTrue);

    final picked = channel.invokeMethod<String>('pick');
    // ignore: avoid_print
    print('EMOJI_KEYBOARD_OPEN');
    await Future<void>.delayed(const Duration(seconds: 4));
    await channel.invokeMethod<void>('cancel');

    expect(await picked, isNull);
  });
}
