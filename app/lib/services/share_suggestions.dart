import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_models.dart';
import '../demo/demo_mode.dart';
import '../features/home/home_screen.dart' show roomAvatarMediaId, roomDisplayName;
import '../providers/chat_providers.dart';
import '../providers/image_cache_provider.dart';

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
/// the chats used most appear directly in the system share sheet, with the
/// other person's profile picture for a 1:1 chat. Picking one there opens
/// Roost straight to that chat's review screen.
class ShareSuggestions {
  ShareSuggestions(this._ref);

  final Ref _ref;

  /// iOS donates natively (AppDelegate's ShareSuggestionDonor): the plugin
  /// hands iOS the picture as a file URL inside Roost's sandbox, which the
  /// share sheet, running in another process, can't read — so it showed no
  /// picture. The native side passes the image data itself instead.
  static const _iosChannel = MethodChannel('roost/share_suggestions');

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
      final room = matches.first;
      final name = roomDisplayName(room, me.id, users);
      final imagePath = await _avatarFile(roomAvatarMediaId(room, me.id, users));
      if (Platform.isIOS) {
        await _iosChannel.invokeMethod<void>(
            'donate', {'conversationIdentifier': roomId, 'name': name, 'imagePath': imagePath});
      } else {
        await _ref.read(shareHandlerProvider).recordSentMessage(
              conversationIdentifier: roomId,
              conversationName: name,
              conversationImageFilePath: imagePath,
              serviceName: 'Roost',
            );
      }
    } catch (_) {
      // Best-effort: only affects the share sheet's suggestions.
    }
  }

  /// The profile picture [mediaId] as a local file (the small preview the
  /// app already caches for avatars), or null without one. A picture that
  /// can't be had leaves the suggestion without it, not out.
  Future<String?> _avatarFile(String? mediaId) async {
    if (mediaId == null) return null;
    try {
      final url = _ref.read(apiClientProvider).mediaPreviewUrl(mediaId);
      return (await _ref.read(imageCacheManagerProvider).getSingleFile(url)).path;
    } catch (_) {
      return null;
    }
  }
}

final shareSuggestionsProvider = Provider<ShareSuggestions>(ShareSuggestions.new);
