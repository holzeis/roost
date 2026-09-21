import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../data/api_client.dart';
import '../data/api_models.dart';
import '../data/ws_client.dart';
import '../features/location/location_service.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final locationServiceProvider = Provider<LocationService>((ref) => LocationService());

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

/// A single room's details (name, isGroup, members) — used wherever a
/// screen is reached without already having an ApiRoom in hand (e.g.
/// IncomingCallScreen, reached from a global listener rather than by
/// tapping a room in a list that already had one).
final roomProvider = FutureProvider.family<ApiRoom, String>(
  (ref, roomId) => ref.watch(apiClientProvider).getRoom(roomId),
);

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

/// Cached per URL — a link preview never changes for the lifetime of the
/// provider container, so refetching on every rebuild would be wasteful.
final linkPreviewProvider = FutureProvider.family<ApiLinkPreview?, String>(
  (ref, url) => ref.watch(apiClientProvider).fetchLinkPreview(url),
);

/// What the composer is currently doing beyond a plain new message: quoting
/// a message to reply to it (FR1.10), or editing one of the sender's own
/// (FR1.13). Lives here rather than as composer-local state because it's
/// set from the message list's long-press menu — a sibling widget — and
/// read by the composer.
sealed class ComposerDraft {
  const ComposerDraft(this.message);
  final ApiMessage message;
}

class ReplyDraft extends ComposerDraft {
  const ReplyDraft(super.message);
}

class EditDraft extends ComposerDraft {
  const EditDraft(super.message);
}

final composerDraftProvider = StateProvider.family<ComposerDraft?, String>((ref, roomId) => null);

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
          unawaited(_ackDelivered([message]));
        case 'reaction.added':
        case 'reaction.removed':
          _applyReactionEvent(event.type, event.payload);
        case 'message.updated':
          final updated = ref.read(wsClientProvider).messageFrom(event);
          if (updated == null || updated.roomId != arg) return;
          final current = state.valueOrNull;
          if (current == null) return;
          state = AsyncData([for (final m in current) if (m.id == updated.id) updated else m]);
        case 'message.deleted':
          final deletedId = event.payload['messageId'] as String?;
          final roomId = event.payload['roomId'] as String?;
          if (deletedId == null || roomId != arg) return;
          final current = state.valueOrNull;
          if (current == null) return;
          state = AsyncData(current.where((m) => m.id != deletedId).toList());
        case 'message.status':
          final messageId = event.payload['messageId'] as String?;
          final status = event.payload['status'] as String?;
          final roomIdForEvent = event.payload['roomId'] as String?;
          if (messageId == null || status == null || roomIdForEvent != arg) return;
          final current = state.valueOrNull;
          if (current == null) return;
          state = AsyncData([
            for (final m in current) if (m.id == messageId) m.copyWith(status: status) else m,
          ]);
      }
    });
    ref.onDispose(sub.close);

    // Server returns newest-first; the chat screen renders oldest-first.
    final history = await ref.read(apiClientProvider).listMessages(arg);
    final ordered = history.reversed.toList();
    unawaited(_ackDelivered(ordered));
    return ordered;
  }

  /// Acks messages from other senders as delivered (FR1.5) the moment this
  /// client actually has them — either from the initial history fetch or a
  /// live message.created push. Best-effort: a failure here just means the
  /// status ticks lag, not that the message itself was lost.
  Future<void> _ackDelivered(Iterable<ApiMessage> messages) async {
    final meId = (await ref.read(meProvider.future)).id;
    final ids = [for (final m in messages) if (m.senderId != meId) m.id];
    if (ids.isEmpty) return;
    await ref.read(apiClientProvider).ackReceipts(roomId, ids, 'delivered');
  }

  /// Acks messages from other senders as seen (FR1.6) once the chat screen
  /// has them visible in the viewport. Called by the screen's own
  /// viewport-visibility tracking, not automatically.
  Future<void> ackSeen(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final meId = ref.read(meProvider).valueOrNull?.id;
    final current = state.valueOrNull;
    if (meId == null || current == null) return;
    final ids = [
      for (final id in messageIds)
        if (current.any((m) => m.id == id && m.senderId != meId && m.status != 'seen')) id,
    ];
    if (ids.isEmpty) return;
    await ref.read(apiClientProvider).ackReceipts(roomId, ids, 'seen');
  }

  /// Signals this user's typing state to the room (FR1.7). The composer
  /// calls this rather than reaching into wsClientProvider directly, so it
  /// stays consistent with every other room action going through this
  /// controller.
  void notifyTyping(bool isTyping) {
    ref.read(wsClientProvider).sendTyping(roomId, isTyping);
  }

  Future<void> send(String body, {String? replyToMessageId}) async {
    // No local append here: the server broadcasts the new message back over
    // the WebSocket to every room member including the sender, so the
    // listener above is the single source of truth for state updates.
    await ref.read(apiClientProvider).sendTextMessage(roomId, body, replyToMessageId: replyToMessageId);
  }

  /// Uploads an image or video (FR2.1/2.2). Same non-mutating pattern as
  /// send: the server broadcasts the resulting message back over the socket.
  Future<void> sendMedia({
    required List<int> bytes,
    required String filename,
    required String contentType,
    required String kind,
    String? replyToMessageId,
  }) async {
    await ref.read(apiClientProvider).uploadMedia(
          roomId,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
          kind: kind,
          replyToMessageId: replyToMessageId,
        );
  }

  /// Edits one of the caller's own text messages (FR1.13). Like send, this
  /// doesn't mutate state directly — the server broadcasts message.updated
  /// back over the WebSocket, handled by the listener in build().
  Future<void> editMessage(String messageId, String body) async {
    await ref.read(apiClientProvider).editMessage(messageId, body);
  }

  /// Forwards a message into a (possibly different) room (FR1.11). Unlike
  /// send/sendMedia, the target room may not be this controller's own room,
  /// so there's nothing here for *this* controller to update — the target
  /// room's own MessagesController (if it's alive) picks up the broadcast.
  Future<void> forwardMessage(String messageId, String toRoomId) async {
    await ref.read(apiClientProvider).forwardMessage(messageId, toRoomId);
  }

  /// Deletes shared media (FR2.5). The server broadcasts message.deleted,
  /// which removes it from state via the listener in build().
  Future<void> deleteMedia(String mediaId) async {
    await ref.read(apiClientProvider).deleteMedia(mediaId);
  }

  /// Deletes a non-media message (FR1.15) — same message.deleted broadcast
  /// as deleteMedia, just for text/location/call messages.
  Future<void> deleteMessage(String messageId) async {
    await ref.read(apiClientProvider).deleteMessage(messageId);
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

/// Who's currently typing in a room (FR1.7), keyed by roomId. Purely
/// derived from `typing` WS events — never fetched or persisted.
final typingUsersProvider = NotifierProvider.family<TypingController, Set<String>, String>(
  TypingController.new,
);

class TypingController extends FamilyNotifier<Set<String>, String> {
  final Map<String, Timer> _timers = {};

  /// How long a typer is shown after their last ping with no explicit stop
  /// — covers a lost "stop" frame (app killed, connection dropped) without
  /// the server needing to track or time anything out itself.
  static const _timeout = Duration(seconds: 6);

  @override
  Set<String> build(String arg) {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      final event = next.valueOrNull;
      if (event == null || event.type != 'typing') return;
      if (event.payload['roomId'] != arg) return;
      final userId = event.payload['userId'] as String?;
      final typing = event.payload['typing'] as bool?;
      if (userId == null || typing == null) return;

      _timers.remove(userId)?.cancel();
      if (typing) {
        state = {...state, userId};
        _timers[userId] = Timer(_timeout, () {
          _timers.remove(userId);
          state = {...state}..remove(userId);
        });
      } else {
        state = {...state}..remove(userId);
      }
    });
    ref.onDispose(() {
      sub.close();
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const {};
  }
}

/// Whether *this* room has an outgoing live location share from the current
/// user active right now (FR3.1-FR3.5) — the message id of that share, or
/// null. Not `.autoDispose`, like typingUsersProvider — the whole point of
/// background tracking is that it keeps running after the user navigates
/// away from the chat screen, so nothing here should tear it down early.
final locationShareProvider = NotifierProvider.family<LocationShareController, String?, String>(
  LocationShareController.new,
);

class LocationShareController extends FamilyNotifier<String?, String> {
  late final String roomId = arg;
  StreamSubscription<Position>? _positionSub;
  Timer? _ttlTimer;

  @override
  String? build(String arg) {
    ref.onDispose(() {
      _positionSub?.cancel();
      _ttlTimer?.cancel();
    });
    return null;
  }

  /// Starts sharing (FR3.1/FR3.2): requests permission, posts the initial
  /// fix, then keeps posting position updates as the device moves until the
  /// TTL elapses (FR3.4) or end() is called (FR3.5). A no-op if a share in
  /// this room is already active.
  Future<void> start(Duration ttl) async {
    if (state != null) return;
    final service = ref.read(locationServiceProvider);
    await service.requestPermission();
    final initial = await service.getCurrentPosition();

    final message = await ref
        .read(apiClientProvider)
        .shareLocation(roomId, lat: initial.latitude, lng: initial.longitude, ttl: ttl);
    state = message.id;

    _positionSub = service.watchPosition().listen((position) {
      final messageId = state;
      if (messageId == null) return;
      unawaited(ref.read(apiClientProvider).updateLocation(messageId, lat: position.latitude, lng: position.longitude));
    });
    _ttlTimer = Timer(ttl, end);
  }

  /// Ends the active share, whether that's FR3.4's TTL timer firing or
  /// FR3.5's manual "stop sharing" — both funnel through here. A no-op if
  /// nothing is currently active.
  Future<void> end() async {
    final messageId = state;
    if (messageId == null) return;
    state = null;
    await _positionSub?.cancel();
    _positionSub = null;
    _ttlTimer?.cancel();
    _ttlTimer = null;
    await ref.read(apiClientProvider).endLocationShare(messageId);
  }
}

/// A call ringing right now that the current user hasn't answered or
/// declined yet, or null. Deliberately global (not `.family` by room) —
/// unlike reactions/location/status, an incoming call has to be shown
/// regardless of which screen is open (could be the home screen, a
/// different chat, anywhere) — see RoostApp's listener in lib/main.dart,
/// which is what actually navigates to the incoming-call screen.
final incomingCallProvider = NotifierProvider<IncomingCallController, IncomingCallInfo?>(
  IncomingCallController.new,
);

class IncomingCallInfo {
  const IncomingCallInfo({required this.roomId, required this.messageId});
  final String roomId;
  final String messageId;
}

class IncomingCallController extends Notifier<IncomingCallInfo?> {
  @override
  IncomingCallInfo? build() {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      final event = next.valueOrNull;
      if (event == null) return;
      final payload = event.payload;
      switch (event.type) {
        case 'message.created':
          if (payload['kind'] != 'call') return;
          final roomId = payload['roomId'] as String?;
          final messageId = payload['id'] as String?;
          final senderId = payload['senderId'] as String?;
          if (roomId == null || messageId == null || senderId == null) return;
          // meProvider may not have resolved yet this early (e.g. right at
          // app start, before the initial getMe() REST call lands) — await
          // it rather than reading synchronously, same as
          // MessagesController._ackDelivered above, so a call arriving in
          // that window isn't silently dropped.
          unawaited(ref.read(meProvider.future).then((me) {
            if (senderId == me.id) return;
            state = IncomingCallInfo(roomId: roomId, messageId: messageId);
          }));
        case 'message.updated':
          // The call was answered elsewhere, declined, or ended before this
          // device acted on it — stop showing it as incoming.
          final current = state;
          if (current == null || payload['id'] != current.messageId) return;
          final call = payload['call'] as Map<String, dynamic>?;
          if (call != null && call['status'] != 'ringing') state = null;
      }
    });
    ref.onDispose(sub.close);
    return null;
  }

  /// Explicitly dismisses the incoming call (the user accepted or declined
  /// it locally) without waiting for a message.updated round-trip.
  void dismiss() => state = null;
}
