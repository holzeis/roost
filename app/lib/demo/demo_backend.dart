import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../data/api_client.dart';
import '../data/api_models.dart';
import '../data/ws_client.dart';
import 'demo_json.dart';
import 'demo_seed.dart';

/// The in-app stand-in for the chat server used by demo mode (App Store
/// review — see lib/demo/demo_mode.dart). Holds users, rooms, messages,
/// reactions and media in memory, seeded by [seedDemo], and answers every
/// [ApiClient] call the way the real server does: each change is broadcast
/// back through [ws] as the same WebSocket event the server would send,
/// since the app's providers only ever update from those events. Nothing
/// here touches the network. Discarded, with everything the reviewer did,
/// when the demo is left.
class DemoBackend {
  DemoBackend({
    DateTime? now,
    this.statusDelay = const Duration(milliseconds: 900),
    this.replyDelay = const Duration(seconds: 2),
  }) {
    seedDemo(this, now ?? DateTime.now());
  }

  /// How long before each step of a sent message's delivered → seen ticks.
  final Duration statusDelay;

  /// How long a family member "types" before answering the reviewer.
  final Duration replyDelay;

  final DemoWsClient ws = DemoWsClient();
  late final DemoApiClient api = DemoApiClient(this);

  late ApiUser me;
  final Map<String, ApiContact> contacts = {};
  final Map<String, ApiRoom> rooms = {};

  /// Per room, oldest first. Reactions live in [reactions], not on these.
  final Map<String, List<ApiMessage>> messages = {};

  /// messageId → emoji → the user ids that reacted with it.
  final Map<String, Map<String, Set<String>>> reactions = {};

  /// Bundled images backing the seeded photos: mediaId → asset path.
  final Map<String, String> assetMedia = {};

  /// Media the reviewer added during the demo: mediaId → bytes.
  final Map<String, Uint8List> uploadedMedia = {};

  /// Videos the reviewer recorded: mediaId → a local file the player reads.
  final Map<String, String> videoFiles = {};

  final List<Timer> _timers = [];
  final Set<String> _roomsAwaitingReply = {};
  int _nextId = 1;
  int _nextReply = 0;

  String newId(String prefix) => 'demo-$prefix-${_nextId++}';

  static const _cannedReplies = [
    'Sounds good! 😊',
    'Haha, love it 😄',
    'Perfect, see you then!',
    'Thanks for letting me know ❤️',
    'Great idea!',
  ];

  // --- seeding helpers (used by demo_seed.dart) ---

  void addContact(ApiContact contact) => contacts[contact.id] = contact;

  void addRoom(ApiRoom room) {
    rooms[room.id] = room;
    messages.putIfAbsent(room.id, () => []);
  }

  void addMessage(ApiMessage message) => messages.putIfAbsent(message.roomId, () => []).add(message);

  void react(String messageId, String userId, String emoji) =>
      reactions.putIfAbsent(messageId, () => {}).putIfAbsent(emoji, () => {}).add(userId);

  // --- lookups ---

  ApiMessage? findMessage(String messageId) {
    for (final list in messages.values) {
      for (final m in list) {
        if (m.id == messageId) return m;
      }
    }
    return null;
  }

  void _replace(ApiMessage updated) {
    final list = messages[updated.roomId]!;
    list[list.indexWhere((m) => m.id == updated.id)] = updated;
  }

  /// [message] as the app sees it: with its reactions attached, relative to
  /// the demo user.
  ApiMessage view(ApiMessage message) {
    final byEmoji = reactions[message.id];
    if (byEmoji == null || byEmoji.isEmpty) return message.copyWith(reactions: const []);
    return message.copyWith(reactions: [
      for (final entry in byEmoji.entries)
        if (entry.value.isNotEmpty)
          ApiReaction(emoji: entry.key, count: entry.value.length, reactedByMe: entry.value.contains(me.id)),
    ]);
  }

  ApiMessageSnippet? snippetFor(String? messageId) {
    final m = messageId == null ? null : findMessage(messageId);
    if (m == null) return null;
    return ApiMessageSnippet(
      id: m.id,
      senderId: m.senderId,
      kind: m.isDeleted ? 'deleted' : m.kind,
      body: m.body,
      mediaId: m.mediaId,
    );
  }

  ApiRoom roomView(ApiRoom room) {
    final list = messages[room.id] ?? const [];
    final last = list.isEmpty ? null : list.last;
    return ApiRoom(
      id: room.id,
      name: room.name,
      isGroup: room.isGroup,
      createdBy: room.createdBy,
      createdAt: room.createdAt,
      members: room.members,
      lastMessageBody: last?.body,
      lastMessageKind: last == null ? null : (last.isDeleted ? 'deleted' : last.kind),
      lastMessageAt: last?.createdAt,
    );
  }

  // --- broadcasting ---

  void emitMessage(String type, ApiMessage message) =>
      ws.emit(WsEvent(type, jsonDecode(jsonEncode(messageToJson(view(message)))) as Map<String, dynamic>));

  void _later(Duration delay, void Function() action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      action();
    });
    _timers.add(timer);
  }

  /// A just-sent message of the demo user's goes delivered, then seen, so
  /// the reviewer sees the ticks change (FR1.5/FR1.6).
  void simulateReceipts(ApiMessage message) {
    for (final (step, status) in [(1, 'delivered'), (2, 'seen')]) {
      _later(statusDelay * step, () {
        final current = findMessage(message.id);
        if (current == null || current.isDeleted) return;
        _replace(current.copyWith(status: status));
        ws.emit(WsEvent('message.status', {'messageId': message.id, 'roomId': message.roomId, 'status': status}));
      });
    }
  }

  /// Someone else in the room types for a moment, then answers with a
  /// canned reply — at most one pending answer per room.
  void simulateReply(String roomId) {
    final room = rooms[roomId];
    if (room == null || !_roomsAwaitingReply.add(roomId)) return;
    final others = room.members.where((id) => id != me.id).toList();
    if (others.isEmpty) {
      _roomsAwaitingReply.remove(roomId);
      return;
    }
    final responder = others[_nextReply % others.length];
    final body = _cannedReplies[_nextReply++ % _cannedReplies.length];
    _later(statusDelay * 2, () {
      ws.emit(WsEvent('typing', {'roomId': roomId, 'userId': responder, 'typing': true}));
      _later(replyDelay, () {
        _roomsAwaitingReply.remove(roomId);
        ws.emit(WsEvent('typing', {'roomId': roomId, 'userId': responder, 'typing': false}));
        final reply = ApiMessage(
          id: newId('msg'),
          roomId: roomId,
          senderId: responder,
          kind: 'text',
          body: body,
          createdAt: DateTime.now(),
        );
        addMessage(reply);
        emitMessage('message.created', reply);
      });
    });
  }

  /// FR1.15, as the server does it: a message someone already saw becomes a
  /// "Deleted message" placeholder; one nobody saw yet disappears.
  void deleteMessage(ApiMessage message) {
    reactions.remove(message.id);
    if (message.mediaId != null) _dropMedia(message.mediaId!);
    if (message.status == 'seen') {
      final placeholder = ApiMessage(
        id: message.id,
        roomId: message.roomId,
        senderId: message.senderId,
        kind: message.kind,
        createdAt: message.createdAt,
        status: message.status,
        deletedAt: DateTime.now(),
      );
      _replace(placeholder);
      emitMessage('message.updated', placeholder);
      return;
    }
    messages[message.roomId]!.removeWhere((m) => m.id == message.id);
    ws.emit(WsEvent('message.deleted', {'messageId': message.id, 'roomId': message.roomId}));
  }

  void _dropMedia(String mediaId) {
    assetMedia.remove(mediaId);
    uploadedMedia.remove(mediaId);
    final path = videoFiles.remove(mediaId);
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  /// A media object's bytes, whether bundled (seeded) or added in the demo.
  Future<Uint8List?> mediaBytes(String mediaId) async {
    final uploaded = uploadedMedia[mediaId];
    if (uploaded != null) return uploaded;
    final asset = assetMedia[mediaId];
    if (asset == null) return null;
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Copies a media object for a forwarded message, the way the server
  /// duplicates rather than shares it.
  String copyMedia(String mediaId) {
    final copy = newId('media');
    if (assetMedia.containsKey(mediaId)) assetMedia[copy] = assetMedia[mediaId]!;
    if (uploadedMedia.containsKey(mediaId)) uploadedMedia[copy] = uploadedMedia[mediaId]!;
    if (videoFiles.containsKey(mediaId)) videoFiles[copy] = videoFiles[mediaId]!;
    return copy;
  }

  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final path in videoFiles.values) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    ws.dispose();
  }
}

/// Thrown for what the demo can't do — calls, which need the family's
/// private network and a second device.
class DemoUnavailableException extends ApiException {
  DemoUnavailableException(String what) : super(409, "$what isn't available in the demo");
}

/// [ApiClient] backed by [DemoBackend] — see its doc comment.
class DemoApiClient extends ApiClient {
  DemoApiClient(this._b);

  final DemoBackend _b;

  ApiMessage _require(String messageId) {
    final m = _b.findMessage(messageId);
    if (m == null || m.isDeleted) throw ApiException(404, 'message not found');
    return m;
  }

  ApiMessage _send(ApiMessage message) {
    _b.addMessage(message);
    _b.emitMessage('message.created', message);
    _b.simulateReceipts(message);
    return _b.view(message);
  }

  @override
  Future<ApiUser> getMe() async => _b.me;

  @override
  Future<ApiUser> updateMe({required String displayName, String? avatarMediaId}) async =>
      _b.me = ApiUser(id: _b.me.id, displayName: displayName, avatarMediaId: avatarMediaId ?? _b.me.avatarMediaId);

  @override
  Future<ApiUser> uploadAvatar({required List<int> bytes, required String filename, required String contentType}) async {
    final mediaId = _b.newId('media');
    _b.uploadedMedia[mediaId] = Uint8List.fromList(bytes);
    return _b.me = ApiUser(id: _b.me.id, displayName: _b.me.displayName, avatarMediaId: mediaId);
  }

  /// Nothing to register: the demo never receives push notifications.
  @override
  Future<void> registerDevice({required String platform, required String pushToken, String tokenType = 'fcm'}) async {}

  @override
  Future<List<ApiContact>> listUsers() async => _b.contacts.values.toList();

  @override
  Future<List<ApiRoom>> listRooms() async {
    final list = _b.rooms.values.map(_b.roomView).toList()
      ..sort((a, b) => (b.lastMessageAt ?? b.createdAt).compareTo(a.lastMessageAt ?? a.createdAt));
    return list;
  }

  @override
  Future<ApiRoom> getRoom(String roomId) async {
    final room = _b.rooms[roomId];
    if (room == null) throw ApiException(404, 'room not found');
    return _b.roomView(room);
  }

  @override
  Future<ApiRoom> createRoom({String? name, required bool isGroup, required List<String> memberIds}) async {
    if (!isGroup && memberIds.length == 1) {
      for (final room in _b.rooms.values) {
        if (!room.isGroup && room.members.contains(memberIds.single)) return _b.roomView(room);
      }
    }
    final room = ApiRoom(
      id: _b.newId('room'),
      name: name,
      isGroup: isGroup,
      createdBy: _b.me.id,
      createdAt: DateTime.now(),
      members: [_b.me.id, ...memberIds],
    );
    _b.addRoom(room);
    return room;
  }

  @override
  Future<List<ApiMessage>> listMessages(String roomId, {DateTime? before, int limit = 50}) async {
    final list = (_b.messages[roomId] ?? const <ApiMessage>[])
        .where((m) => before == null || m.createdAt.isBefore(before))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.take(limit).map(_b.view).toList();
  }

  @override
  Future<ApiMessage> sendTextMessage(String roomId, String body, {String? replyToMessageId}) async {
    final sent = _send(ApiMessage(
      id: _b.newId('msg'),
      roomId: roomId,
      senderId: _b.me.id,
      kind: 'text',
      body: body,
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      replyTo: _b.snippetFor(replyToMessageId),
    ));
    _b.simulateReply(roomId);
    return sent;
  }

  @override
  Future<ApiMessage> editMessage(String messageId, String body) async {
    final updated = _require(messageId).copyWith(body: body, editedAt: DateTime.now());
    _b._replace(updated);
    _b.emitMessage('message.updated', updated);
    return _b.view(updated);
  }

  @override
  Future<ApiMessage> forwardMessage(String messageId, String toRoomId) async {
    final original = _require(messageId);
    return _send(ApiMessage(
      id: _b.newId('msg'),
      roomId: toRoomId,
      senderId: _b.me.id,
      kind: original.kind,
      body: original.body,
      mediaId: original.mediaId == null ? null : _b.copyMedia(original.mediaId!),
      media: original.media,
      location: original.location,
      createdAt: DateTime.now(),
      forwarded: true,
    ));
  }

  /// No previews in the demo: fetching arbitrary URLs is the server's job.
  @override
  Future<ApiLinkPreview?> fetchLinkPreview(String url) async => null;

  @override
  Future<List<ApiMessage>> searchMessages(String roomId, String query) async {
    final needle = query.toLowerCase();
    final list = (_b.messages[roomId] ?? const <ApiMessage>[])
        .where((m) => !m.isDeleted && (m.body ?? '').toLowerCase().contains(needle))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.map(_b.view).toList();
  }

  @override
  Future<ApiMessage> uploadMedia(
    String roomId, {
    required List<int> bytes,
    required String filename,
    required String contentType,
    required String kind,
    String? replyToMessageId,
    String? caption,
  }) async {
    final mediaId = _b.newId('media');
    if (kind == 'video') {
      final dir = await Directory.systemTemp.createTemp('roost-demo-');
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      _b.videoFiles[mediaId] = file.path;
    } else {
      _b.uploadedMedia[mediaId] = Uint8List.fromList(bytes);
    }
    return _send(ApiMessage(
      id: _b.newId('msg'),
      roomId: roomId,
      senderId: _b.me.id,
      kind: kind,
      body: (caption?.isEmpty ?? true) ? null : caption,
      mediaId: mediaId,
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      replyTo: _b.snippetFor(replyToMessageId),
    ));
  }

  @override
  Future<List<int>> downloadMedia(String mediaId) async {
    final path = _b.videoFiles[mediaId];
    if (path != null) return File(path).readAsBytes();
    final bytes = await _b.mediaBytes(mediaId);
    if (bytes == null) throw ApiException(404, 'media not found');
    return bytes;
  }

  @override
  Future<void> deleteMedia(String mediaId) async {
    for (final list in _b.messages.values) {
      for (final m in list) {
        if (m.mediaId == mediaId) return _b.deleteMessage(m);
      }
    }
    throw ApiException(404, 'media not found');
  }

  @override
  Future<void> deleteMessage(String messageId) async => _b.deleteMessage(_require(messageId));

  /// Images are served by DemoCacheManager from this made-up scheme; a
  /// recorded video is played straight from its local file.
  @override
  String mediaUrl(String mediaId) {
    final path = _b.videoFiles[mediaId];
    return path != null ? Uri.file(path).toString() : 'demo://media/$mediaId';
  }

  @override
  String mediaPreviewUrl(String mediaId) => mediaUrl(mediaId);

  @override
  Future<void> addReaction(String messageId, String emoji) async {
    _require(messageId);
    if (!(_b.reactions.putIfAbsent(messageId, () => {}).putIfAbsent(emoji, () => {}).add(_b.me.id))) return;
    _b.ws.emit(WsEvent('reaction.added', {'messageId': messageId, 'userId': _b.me.id, 'emoji': emoji}));
  }

  @override
  Future<void> removeReaction(String messageId, String emoji) async {
    if (!(_b.reactions[messageId]?[emoji]?.remove(_b.me.id) ?? false)) return;
    _b.ws.emit(WsEvent('reaction.removed', {'messageId': messageId, 'userId': _b.me.id, 'emoji': emoji}));
  }

  /// The demo's family members don't track what the reviewer has read.
  @override
  Future<void> ackReceipts(String roomId, List<String> messageIds, String status) async {}

  @override
  Future<ApiMessage> shareLocation(String roomId, {required double lat, required double lng, required Duration ttl}) async =>
      _send(ApiMessage(
        id: _b.newId('msg'),
        roomId: roomId,
        senderId: _b.me.id,
        kind: 'location',
        createdAt: DateTime.now(),
        location: ApiLocationShare(lat: lat, lng: lng, expiresAt: DateTime.now().add(ttl)),
      ));

  ApiMessage _updateLocation(String messageId, ApiLocationShare Function(ApiLocationShare) change) {
    final existing = _require(messageId);
    final share = existing.location;
    if (share == null) throw ApiException(400, 'not a location share');
    final updated = existing.copyWith(location: change(share));
    _b._replace(updated);
    _b.emitMessage('message.updated', updated);
    return _b.view(updated);
  }

  @override
  Future<ApiMessage> updateLocation(String messageId, {required double lat, required double lng}) async =>
      _updateLocation(messageId,
          (s) => ApiLocationShare(lat: lat, lng: lng, expiresAt: s.expiresAt, endedAt: s.endedAt));

  @override
  Future<ApiMessage> endLocationShare(String messageId) async => _updateLocation(messageId,
      (s) => ApiLocationShare(lat: s.lat, lng: s.lng, expiresAt: s.expiresAt, endedAt: s.endedAt ?? DateTime.now()));

  /// No static map snapshots in the demo (the server renders those); an
  /// ended share keeps its fallback look.
  @override
  Future<ApiMessage> fetchLocationSnapshot(String messageId) async => _b.view(_require(messageId));

  @override
  Future<String> mintLiveKitToken(String roomId) async => throw DemoUnavailableException('Calling');

  @override
  Future<ApiMessage> startCall(String roomId) async => throw DemoUnavailableException('Calling');

  @override
  Future<void> acceptCall(String callId) async => throw DemoUnavailableException('Calling');

  @override
  Future<void> declineCall(String callId) async {}

  @override
  Future<void> leaveCall(String callId) async {}
}

/// [WsClient] for the demo: no socket, just the events [DemoBackend] emits.
class DemoWsClient extends WsClient {
  final _events = StreamController<WsEvent>.broadcast();

  @override
  void connect() {}

  /// Nothing to reconnect to — the demo's events never stop.
  @override
  void reconnectNow() {}

  @override
  Stream<WsEvent> get events => _events.stream;

  void emit(WsEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// The demo's family members can't see the reviewer typing.
  @override
  void sendTyping(String roomId, bool isTyping) {}

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
