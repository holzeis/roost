import 'package:flutter_test/flutter_test.dart';
import 'package:roost/util/time_format.dart';

void main() {
  group('formatActivityTime', () {
    test('formats today as a time of day', () {
      final now = DateTime.now();
      final today6pm = DateTime(now.year, now.month, now.day, 18, 12);
      expect(formatActivityTime(today6pm), '6:12 PM');
    });

    test('formats midnight correctly as 12 AM', () {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day, 0, 5);
      expect(formatActivityTime(midnight), '12:05 AM');
    });

    test('formats yesterday', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      expect(formatActivityTime(yesterday), 'Yesterday');
    });

    test('formats 3 days ago as a weekday name', () {
      final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
      final formatted = formatActivityTime(threeDaysAgo);
      expect(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], contains(formatted));
    });

    test('formats more than a week ago as a date', () {
      final longAgo = DateTime(2020, 3, 14);
      expect(formatActivityTime(longAgo), '3/14/20');
    });
  });
}
