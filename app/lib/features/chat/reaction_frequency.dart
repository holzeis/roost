import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The quick-reaction picker's default set, before any usage data exists —
/// also the tie-break order once every candidate has the same count, so
/// the picker doesn't reorder itself on the very first few reactions.
const defaultQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

const _quickReactionSlots = 6;
const _prefsKey = 'reaction_frequency_v1';

/// The quick-reaction picker's current top emoji, ranked by how often this
/// user has actually picked each one (recordUse), persisted across app
/// launches. Starts at [defaultQuickReactions] until usage data loads (or
/// forever, if there isn't any yet) — favors "shows something reasonable
/// immediately" over blocking the picker's first paint on disk I/O.
final quickReactionsProvider =
    AsyncNotifierProvider<QuickReactionsController, List<String>>(
        QuickReactionsController.new);

class QuickReactionsController extends AsyncNotifier<List<String>> {
  @override
  FutureOr<List<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    return _rank(_readCounts(prefs));
  }

  // Always a mutable, growable map — recordUse writes into whatever this
  // returns directly, and a `const {}` (or the literal `{}` in a const
  // context) is neither.
  Map<String, int> _readCounts(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return <String, int>{};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, v as int));
    } catch (_) {
      // Corrupt/foreign data under this key shouldn't take the picker down
      // with it — just start over as if there were no usage data yet.
      return <String, int>{};
    }
  }

  List<String> _rank(Map<String, int> counts) {
    if (counts.isEmpty) return defaultQuickReactions;
    final candidates = {...defaultQuickReactions, ...counts.keys}.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
    return candidates.take(_quickReactionSlots).toList();
  }

  /// Records a pick — whether from the quick list or the custom-emoji
  /// entry — and re-ranks immediately so the picker reflects it next time
  /// it opens.
  Future<void> recordUse(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    final counts = _readCounts(prefs);
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    await prefs.setString(_prefsKey, jsonEncode(counts));
    state = AsyncData(_rank(counts));
  }
}
