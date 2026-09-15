/// Room-list / message timestamp formatting matching
/// docs/mockups/roost-mockups-utility-dense.html: "6:12 PM" for today,
/// "Yesterday", a short weekday for the last week, otherwise a date.
/// Hand-rolled rather than pulling in `intl` for a handful of formats.
String formatActivityTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final daysAgo = today.difference(day).inDays;

  if (daysAgo == 0) return _timeOfDay(local);
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) return _weekday(local.weekday);
  return '${local.month}/${local.day}/${local.year % 100}';
}

String _timeOfDay(DateTime dt) {
  final hour24 = dt.hour;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = hour24 < 12 ? 'AM' : 'PM';
  return '$hour12:$minute $period';
}

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _weekday(int weekday1to7) => _weekdayNames[weekday1to7 - 1];

/// "How much longer" label for an active location share (FR3.6), e.g. "12m
/// left" or "1h 5m left". A non-positive duration (already expired) reads
/// as "Ending…" rather than a negative/zero time, since the client's own
/// copy of `now` can lag the server's by the time this renders.
String formatRemaining(Duration remaining) {
  if (remaining.inSeconds <= 0) return 'Ending…';
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m left' : '${hours}h left';
  if (minutes > 0) return '${minutes}m left';
  return '<1m left';
}
