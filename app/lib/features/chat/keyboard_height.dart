import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers how tall the system keyboard is when fully open, per
/// orientation, so the composer's attach tray can take exactly its place:
/// switching between the two then doesn't move the message bar. Kept on the
/// device so the first switch after a relaunch is right too.
class KeyboardHeightMemory {
  KeyboardHeightMemory(this._prefs);

  static const _prefPrefix = 'keyboardHeight.';

  /// Used until a real keyboard has been seen: a typical iPhone keyboard
  /// with its suggestions bar, including the home-indicator area.
  static const fallbackPortrait = 336.0;
  static const fallbackLandscape = 210.0;

  final Future<SharedPreferences> Function() _prefs;
  final Map<Orientation, double> _heights = {};

  Future<void> load() async {
    try {
      final prefs = await _prefs();
      for (final orientation in Orientation.values) {
        final stored = prefs.getDouble('$_prefPrefix${orientation.name}');
        if (stored != null) _heights.putIfAbsent(orientation, () => stored);
      }
    } catch (_) {
      // Falls back to the defaults until a keyboard is seen.
    }
  }

  double heightFor(Orientation orientation) =>
      _heights[orientation] ??
      (orientation == Orientation.portrait ? fallbackPortrait : fallbackLandscape);

  /// Records a fully open keyboard's height.
  void record(Orientation orientation, double height) {
    if (height <= 0 || (_heights[orientation] ?? -1) == height) return;
    _heights[orientation] = height;
    unawaited(() async {
      try {
        await (await _prefs()).setDouble('$_prefPrefix${orientation.name}', height);
      } catch (_) {}
    }());
  }
}

final keyboardHeightProvider = Provider<KeyboardHeightMemory>((ref) {
  final memory = KeyboardHeightMemory(SharedPreferences.getInstance);
  unawaited(memory.load());
  return memory;
});

/// How tall the attach tray must be for the message bar above it to stay
/// put: together with [bottomPadding] (the safe area below it) and
/// [keyboardInset] (however much keyboard is on screen at this moment,
/// mid-animation included), it always adds up to [keyboardHeight]. So while
/// the keyboard slides away the tray grows into the space it frees, and
/// while the keyboard slides up the tray shrinks out of its way.
double attachTrayHeight({
  required double keyboardHeight,
  required double keyboardInset,
  required double bottomPadding,
}) =>
    math.max(0, keyboardHeight - keyboardInset - bottomPadding);
