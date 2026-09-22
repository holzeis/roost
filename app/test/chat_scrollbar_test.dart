import 'package:flutter_test/flutter_test.dart';
import 'package:roost/features/chat/chat_screen.dart';

void main() {
  group('scrollbarThumbTop', () {
    test('sits at the bottom of the track when at the newest messages (fraction 0)', () {
      expect(scrollbarThumbTop(200, 36, 0), 164);
    });

    test('sits at the top of the track when at the oldest loaded messages (fraction 1)', () {
      expect(scrollbarThumbTop(200, 36, 1), 0);
    });

    test('sits halfway up the track at fraction 0.5', () {
      expect(scrollbarThumbTop(200, 36, 0.5), 82);
    });

    test('never goes negative when the thumb is taller than the track', () {
      expect(scrollbarThumbTop(20, 36, 0), 0);
    });
  });
}
