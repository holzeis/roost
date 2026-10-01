import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/features/chat/keyboard_height.dart';

void main() {
  group('attachTrayHeight', () {
    test('with the keyboard gone, the tray plus the safe area fill its full height', () {
      expect(attachTrayHeight(keyboardHeight: 300, keyboardInset: 0, bottomPadding: 34), 266);
    });

    test('mid-switch, the tray fills exactly what the keyboard has vacated', () {
      expect(attachTrayHeight(keyboardHeight: 300, keyboardInset: 120, bottomPadding: 0), 180);
    });

    test('with the keyboard fully up, the tray has no room', () {
      expect(attachTrayHeight(keyboardHeight: 300, keyboardInset: 300, bottomPadding: 0), 0);
      expect(attachTrayHeight(keyboardHeight: 300, keyboardInset: 310, bottomPadding: 0), 0, reason: 'never negative');
    });
  });

  group('KeyboardHeightMemory', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('falls back to a typical keyboard until one has been seen', () {
      final memory = KeyboardHeightMemory(SharedPreferences.getInstance);
      expect(memory.heightFor(Orientation.portrait), KeyboardHeightMemory.fallbackPortrait);
      expect(memory.heightFor(Orientation.landscape), KeyboardHeightMemory.fallbackLandscape);
    });

    test('remembers the real height per orientation, across launches', () async {
      final first = KeyboardHeightMemory(SharedPreferences.getInstance)
        ..record(Orientation.portrait, 291)
        ..record(Orientation.landscape, 199);
      expect(first.heightFor(Orientation.portrait), 291);
      await Future<void>.delayed(Duration.zero);

      final relaunched = KeyboardHeightMemory(SharedPreferences.getInstance);
      await relaunched.load();
      expect(relaunched.heightFor(Orientation.portrait), 291);
      expect(relaunched.heightFor(Orientation.landscape), 199);
    });

    test('ignores a closed keyboard', () {
      final memory = KeyboardHeightMemory(SharedPreferences.getInstance)..record(Orientation.portrait, 0);
      expect(memory.heightFor(Orientation.portrait), KeyboardHeightMemory.fallbackPortrait);
    });
  });
}
