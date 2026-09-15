import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/api_models.dart';
import '../data/ws_client.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// One WebSocket connection for the app's lifetime (docs/architecture-overview.md:
/// "signaling and media are separate paths" — this carries chat signaling).
final wsClientProvider = Provider<WsClient>((ref) {
  final client = WsClient()..connect();
  ref.onDispose(client.dispose);
  return client;
});

final wsEventsProvider = StreamProvider<WsEvent>((ref) => ref.watch(wsClientProvider).events);

final meProvider = FutureProvider<ApiUser>((ref) => ref.watch(apiClientProvider).getMe());

final usersProvider = FutureProvider<List<ApiContact>>((ref) => ref.watch(apiClientProvider).listUsers());

/// O(1) id -> contact lookups, e.g. for resolving a 1:1 room's display name
/// or a message sender's name, without re-scanning the list each time.
final usersByIdProvider = Provider<AsyncValue<Map<String, ApiContact>>>((ref) {
  return ref.watch(usersProvider).whenData((users) => {for (final u in users) u.id: u});
});

final roomsProvider = AsyncNotifierProvider<RoomsController, List<ApiRoom>>(RoomsController.new);

class RoomsController extends AsyncNotifier<List<ApiRoom>> {
  @override
  FutureOr<List<ApiRoom>> build() async {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      // Any inbound message can change room ordering/preview, regardless of
      // which room it's for, so just refresh the list.
      if (next.valueOrNull != null) unawaited(refresh());
    });
    ref.onDispose(sub.close);
    return ref.read(apiClientProvider).listRooms();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(() => ref.read(apiClientProvider).listRooms());
  }

  Future<ApiRoom> createRoom({String? name, required bool isGroup, required List<String> memberIds}) async {
    final room = await ref.read(apiClientProvider).createRoom(name: name, isGroup: isGroup, memberIds: memberIds);
    await refresh();
    return room;
  }
}

final messagesProvider = AsyncNotifierProvider.family<MessagesController, List<ApiMessage>, String>(
  MessagesController.new,
);

class MessagesController extends FamilyAsyncNotifier<List<ApiMessage>, String> {
  late final String roomId = arg;

  @override
  FutureOr<List<ApiMessage>> build(String arg) async {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      final event = next.valueOrNull;
      if (event == null) return;
      switch (event.type) {
        case 'message.created':
          final message = ref.read(wsClientProvider).messageFrom(event);
          if (message == null || message.roomId != arg) return;
          final current = state.valueOrNull ?? const <ApiMessage>[];
          if (current.any((m) => m.id == message.id)) return;
          state = AsyncData([...current, message]);
        case 'reaction.added':
        case 'reaction.removed':
          _applyReactionEvent(event.type, event.payload);
        case 'message.deleted':
          final deletedId = event.payload['messageId'] as String?;
          final roomId = event.payload['roomId'] as String?;
          if (deletedId == null || roomId != arg) return;
          final current = state.valueOrNull;
          if (current == null) return;
          state = AsyncData(current.where((m) => m.id != deletedId).toList());
      }
    });
    ref.onDispose(sub.close);

    // Server returns newest-first; the chat screen renders oldest-first.
    final history = await ref.read(apiClientProvider).listMessages(arg);
    return history.reversed.toList();
  }

  Future<void> send(String body) async {
    // No local append here: the server broadcasts the new message back over
    // the WebSocket to every room member including the sender, so the
    // listener above is the single source of truth for state updates.
    await ref.read(apiClientProvider).sendTextMessage(roomId, body);
  }

  /// Uploads an image or video (FR2.1/2.2). Same non-mutating pattern as
  /// send: the server broadcasts the resulting message back over the socket.
  Future<void> sendMedia({
    required List<int> bytes,
    required String filename,
    required String contentType,
    required String kind,
  }) async {
    await ref.read(apiClientProvider).uploadMedia(
          roomId,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
          kind: kind,
        );
  }

  /// Deletes shared media (FR2.5). The server broadcasts message.deleted,
  /// which removes it from state via the listener in build().
  Future<void> deleteMedia(String mediaId) async {
    await ref.read(apiClientProvider).deleteMedia(mediaId);
  }

  /// Adds or removes the caller's own reaction (FR1.9). Like send, this
  /// doesn't mutate state directly — the server broadcasts the change back
  /// over the WebSocket to every room member including the actor, and
  /// _applyReactionEvent is the single place state actually changes.
  Future<void> toggleReaction(String messageId, String emoji) async {
    final matches = (state.valueOrNull ?? const <ApiMessage>[]).where((m) => m.id == messageId);
    final message = matches.isEmpty ? null : matches.first;
    final alreadyReacted = message?.reactions.any((r) => r.emoji == emoji && r.reactedByMe) ?? false;
    final api = ref.read(apiClientProvider);
    if (alreadyReacted) {
      await api.removeReaction(messageId, emoji);
    } else {
      await api.addReaction(messageId, emoji);
    }
  }

  void _applyReactionEvent(String type, Map<String, dynamic> payload) {
    final messageId = payload['messageId'] as String?;
    final userId = payload['userId'] as String?;
    final emoji = payload['emoji'] as String?;
    final current = state.valueOrNull;
    if (messageId == null || userId == null || emoji == null || current == null) return;

    final meId = ref.read(meProvider).valueOrNull?.id;
    state = AsyncData([
      for (final m in current)
        if (m.id == messageId) _withReactionChange(m, type, userId, emoji, meId) else m,
    ]);
  }

  ApiMessage _withReactionChange(ApiMessage message, String type, String userId, String emoji, String? meId) {
    final reactions = List<ApiReaction>.from(message.reactions);
    final index = reactions.indexWhere((r) => r.emoji == emoji);

    if (type == 'reaction.added') {
      if (index >= 0) {
        final existing = reactions[index];
        reactions[index] = ApiReaction(
          emoji: emoji,
          count: existing.count + 1,
          reactedByMe: existing.reactedByMe || userId == meId,
        );
      } else {
        reactions.add(ApiReaction(emoji: emoji, count: 1, reactedByMe: userId == meId));
      }
    } else if (index >= 0) {
      final existing = reactions[index];
      final newCount = existing.count - 1;
      if (newCount <= 0) {
        reactions.removeAt(index);
      } else {
        reactions[index] = ApiReaction(
          emoji: emoji,
          count: newCount,
          reactedByMe: existing.reactedByMe && userId != meId,
        );
      }
    }
    return message.copyWith(reactions: reactions);
  }
}
