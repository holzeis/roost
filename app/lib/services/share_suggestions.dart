import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_models.dart';
import '../demo/demo_mode.dart';
import '../features/home/home_screen.dart' show roomDisplayName;
import '../providers/chat_providers.dart';

/// The share_handler platform plugin, behind a provider so tests can use a
/// fake instead of the real platform channel.
final shareHandlerProvider = Provider<ShareHandlerPlatform>((ref) => ShareHandlerPlatform.instance);

/// How often the user has sent to each chat, kept on this device — what
/// ranks chats in the "Share to…" picker, most-used first.
class ChatUsage {
  ChatUsage(this._prefs);

  static const prefKey = 'chatUsage';

  final Future<SharedPreferences> Function() _prefs;

  Future<Map<String, int>> counts() async {
    try {
      final raw = (await _prefs()).getString(prefKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return {};
    }
  }

  Future<void> recordSend(String roomId) async {
    try {
      final counts = await this.counts();
      counts[roomId] = (counts[roomId] ?? 0) + 1;
      await (await _prefs()).setString(prefKey, jsonEncode(counts));
    } catch (_) {
      // Only affects ordering in the share picker.
    }
  }
}

/// [rooms] ordered for the "Share to…" picker: most sent-to first (per
/// [counts]), then most recently active.
List<ApiRoom> rankRoomsForSharing(List<ApiRoom> rooms, Map<String, int> counts) {
  DateTime activity(ApiRoom r) => r.lastMessageAt ?? r.createdAt;
  return [...rooms]..sort((a, b) {
      final byUse = (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0);
      return byUse != 0 ? byUse : activity(b).compareTo(activity(a));
    });
}

final chatUsageProvider = Provider<ChatUsage>((ref) => ChatUsage(SharedPreferences.getInstance));

/// Reports each chat the user sends to: counted for the in-app picker, and
/// passed to the OS (share_handler's recordSentMessage — an
/// INSendMessageIntent donation on iOS, a sharing shortcut on Android) so
/// the chats used most appear directly in the system share sheet. Picking
/// one there opens Roost straight to that chat's review screen.
class ShareSuggestions {
  ShareSuggestions(this._ref);

  final Ref _ref;

  Future<void> recordSent(String roomId) async {
    await _ref.read(chatUsageProvider).recordSend(roomId);
    // Demo chats are made up; they don't belong in the system share sheet.
    if (_ref.read(demoModeProvider).enabled) return;
    try {
      final rooms = await _ref.read(roomsProvider.future);
      final matches = rooms.where((r) => r.id == roomId);
      if (matches.isEmpty) return;
      final me = await _ref.read(meProvider.future);
      // Awaited, not read from the cache: right after launch the contacts
      // may not be loaded yet, and a 1:1 chat is named after its contact.
      final users = {for (final u in await _ref.read(usersProvider.future)) u.id: u};
      await _ref.read(shareHandlerProvider).recordSentMessage(
            conversationIdentifier: roomId,
            conversationName: roomDisplayName(matches.first, me.id, users),
            serviceName: 'Roost',
          );
    } catch (_) {
      // Best-effort: only affects the share sheet's suggestions.
    }
  }
}

final shareSuggestionsProvider = Provider<ShareSuggestions>(ShareSuggestions.new);
