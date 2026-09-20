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

  group('formatDateDivider', () {
    test('formats today as "Today"', () {
      expect(formatDateDivider(DateTime.now()), 'Today');
    });

    test('formats yesterday as "Yesterday"', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      expect(formatDateDivider(yesterday), 'Yesterday');
    });

    test('formats 3 days ago as a full weekday name', () {
      final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
      final formatted = formatDateDivider(threeDaysAgo);
      expect(
        ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
        contains(formatted),
      );
    });

    test('formats exactly a week ago as a short date, not a weekday', () {
      final aWeekAgo = DateTime.now().subtract(const Duration(days: 7));
      final formatted = formatDateDivider(aWeekAgo);
      expect(
        ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
        isNot(contains(formatted)),
      );
    });

    test('formats more than a week ago as "Weekday, day Month"', () {
      expect(formatDateDivider(DateTime(2026, 9, 11)), 'Fri, 11 Sep');
    });
  });

  group('formatRemaining', () {
    test('formats minutes only', () {
      expect(formatRemaining(const Duration(minutes: 12)), '12m left');
    });

    test('formats hours and minutes', () {
      expect(formatRemaining(const Duration(hours: 1, minutes: 5)), '1h 5m left');
    });

    test('formats an exact hour without a minutes remainder', () {
      expect(formatRemaining(const Duration(hours: 2)), '2h left');
    });

    test('formats under a minute', () {
      expect(formatRemaining(const Duration(seconds: 30)), '<1m left');
    });

    test('formats zero or negative as ending', () {
      expect(formatRemaining(Duration.zero), 'Ending…');
      expect(formatRemaining(const Duration(seconds: -5)), 'Ending…');
    });
  });
}
