import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The system's own emoji keyboard isn't available here: not iOS, or the
/// user has it turned off. The caller shows the in-app picker instead.
class SystemEmojiKeyboardUnavailable implements Exception {
  const SystemEmojiKeyboardUnavailable();
}

/// Picks one emoji with iOS's own emoji keyboard — the same one the user
/// types emoji with everywhere else (see ios/Runner/EmojiKeyboard.swift).
/// Android has no way to open its keyboard straight on emoji, so there the
/// in-app picker stays.
class SystemEmojiKeyboard {
  const SystemEmojiKeyboard();

  static const _channel = MethodChannel('roost/emoji_keyboard');

  /// The emoji picked, or null if the user cancelled. Throws
  /// [SystemEmojiKeyboardUnavailable] when the system keyboard can't be used.
  Future<String?> pick() async {
    if (!Platform.isIOS) throw const SystemEmojiKeyboardUnavailable();
    try {
      return await _channel.invokeMethod<String>('pick');
    } on PlatformException {
      throw const SystemEmojiKeyboardUnavailable();
    } on MissingPluginException {
      throw const SystemEmojiKeyboardUnavailable();
    }
  }
}

final systemEmojiKeyboardProvider = Provider<SystemEmojiKeyboard>((ref) => const SystemEmojiKeyboard());
