import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:roost/data/api_client.dart';
import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/location/location_service.dart';

/// Stands in for the real platform channel behind ImagePicker.pickImage —
/// there's no real camera/gallery under `flutter test`, so without this any
/// code path that reaches ImagePicker would hang or throw
/// MissingPluginException. Returns a fixed in-memory XFile regardless of
/// source, which is enough for tests that only care about what happens
/// after a file is picked, not the picker UI itself.
class FakeImagePickerPlatform extends ImagePickerPlatform {
  FakeImagePickerPlatform(this.bytes, {this.name = 'photo.jpg', this.mimeType = 'image/jpeg'});

  final Uint8List bytes;
  final String name;
  final String mimeType;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    return XFile.fromData(bytes, name: name, mimeType: mimeType);
  }

  /// Backs pickMultipleMedia (the attach tray's "Photos" option) — a single
  /// fixed file is enough to prove the multi-pick path sends what it's
  /// given, without needing a real multi-select UI under test.
  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) async {
    return [XFile.fromData(bytes, name: name, mimeType: mimeType)];
  }

  /// Backs pickVideo (the attach tray's "Video" option, and previously the
  /// composer's own long-press chooser) — pickImage and pickVideo go
  /// through separate platform methods even though they share this same
  /// fake's fixed bytes/name/mimeType.
  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async {
    return XFile.fromData(bytes, name: name, mimeType: mimeType);
  }
}

/// In-memory stand-ins for the network layer, used by widget tests so they
/// never make a real HTTP/WebSocket call. Overriding a method on a
/// non-final class is enough in Dart — no separate interface needed.
///
/// [ws] mirrors the real server's behavior of broadcasting a change back to
/// the actor over the socket rather than the REST response being the source
/// of truth — MessagesController relies entirely on that broadcast to
/// update its state (see chat_providers.dart), so a fake that never emits
/// anything would leave the UI never updating in tests.
class FakeApiClient extends ApiClient {
  FakeApiClient(this.ws);

  final FakeWsClient ws;
  ApiUser me = const ApiUser(id: 'me', displayName: 'Dev User');
  List<ApiContact> contacts = const [];
  List<ApiRoom> rooms = [];
  final Map<String, List<ApiMessage>> messagesByRoom = {};
  int _nextMessageId = 1;

  @override
  Future<ApiUser> getMe() async => me;

  @override
  Future<ApiUser> updateMe({required String displayName, String? avatarMediaId}) async {
    me = ApiUser(id: me.id, displayName: displayName, avatarMediaId: avatarMediaId);
    return me;
  }

  @override
  Future<ApiUser> uploadAvatar({
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) async {
    final mediaId = 'avatar-media-${_nextMediaId++}';
    mediaBytesById[mediaId] = bytes;
    me = ApiUser(id: me.id, displayName: me.displayName, avatarMediaId: mediaId);
    return me;
  }

  @override
  Future<List<ApiContact>> listUsers() async => contacts;

  @override
  Future<List<ApiRoom>> listRooms() async => rooms;

  @override
  Future<ApiRoom> getRoom(String roomId) async => rooms.firstWhere((r) => r.id == roomId);

  @override
  Future<ApiRoom> createRoom({String? name, required bool isGroup, required List<String> memberIds}) async {
    final room = ApiRoom(
      id: 'room-${rooms.length + 1}',
      name: name,
      isGroup: isGroup,
      createdBy: me.id,
      createdAt: DateTime.now(),
      members: [me.id, ...memberIds],
    );
    rooms = [...rooms, room];
    return room;
  }

  @override
  Future<List<ApiMessage>> listMessages(String roomId, {DateTime? before, int limit = 50}) async =>
      List.of(messagesByRoom[roomId] ?? const []);

  @override
  Future<ApiMessage> sendTextMessage(String roomId, String body, {String? replyToMessageId}) async {
    final message = ApiMessage(
      id: 'msg-${_nextMessageId++}',
      roomId: roomId,
      senderId: me.id,
      kind: 'text',
      body: body,
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      replyTo: replyToMessageId != null ? _snippetFor(replyToMessageId) : null,
    );
    messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(message))) as Map<String, dynamic>));
    return message;
  }

  @override
  Future<ApiMessage> editMessage(String messageId, String body) async {
    for (final entry in messagesByRoom.entries) {
      final index = entry.value.indexWhere((m) => m.id == messageId);
      if (index == -1) continue;
      final updated = entry.value[index].copyWith(body: body, editedAt: DateTime.now());
      entry.value[index] = updated;
      ws.emit(WsEvent('message.updated', jsonDecode(jsonEncode(_messageJson(updated))) as Map<String, dynamic>));
      return updated;
    }
    throw ApiException(404, 'not found');
  }

  @override
  Future<ApiMessage> forwardMessage(String messageId, String toRoomId) async {
    ApiMessage? original;
    for (final list in messagesByRoom.values) {
      final matches = list.where((m) => m.id == messageId);
      if (matches.isNotEmpty) {
        original = matches.first;
        break;
      }
    }
    if (original == null) throw ApiException(404, 'not found');

    String? newMediaId;
    if (original.mediaId != null) {
      newMediaId = 'media-${_nextMediaId++}';
      mediaBytesById[newMediaId] = List.of(mediaBytesById[original.mediaId] ?? const []);
    }
    final forwarded = ApiMessage(
      id: 'msg-${_nextMessageId++}',
      roomId: toRoomId,
      senderId: me.id,
      kind: original.kind,
      body: original.body,
      mediaId: newMediaId,
      createdAt: DateTime.now(),
      forwarded: true,
    );
    messagesByRoom.putIfAbsent(toRoomId, () => []).add(forwarded);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(forwarded))) as Map<String, dynamic>));
    return forwarded;
  }

  Map<String, ApiLinkPreview> linkPreviewsByUrl = {};

  @override
  Future<ApiLinkPreview?> fetchLinkPreview(String url) async => linkPreviewsByUrl[url];

  ApiMessageSnippet? _snippetFor(String messageId) {
    for (final list in messagesByRoom.values) {
      final matches = list.where((m) => m.id == messageId);
      if (matches.isNotEmpty) {
        final m = matches.first;
        return ApiMessageSnippet(
            id: m.id, senderId: m.senderId, kind: m.kind, body: m.body, mediaId: m.mediaId);
      }
    }
    return null;
  }

  @override
  Future<List<ApiMessage>> searchMessages(String roomId, String query) async {
    return (messagesByRoom[roomId] ?? const [])
        .where((m) => (m.body ?? '').toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  @override
  Future<void> addReaction(String messageId, String emoji) async {
    ws.emit(WsEvent('reaction.added', {'messageId': messageId, 'userId': me.id, 'emoji': emoji}));
  }

  @override
  Future<void> removeReaction(String messageId, String emoji) async {
    ws.emit(WsEvent('reaction.removed', {'messageId': messageId, 'userId': me.id, 'emoji': emoji}));
  }

  /// Records every ackReceipts call (roomId, messageIds, status) so tests
  /// can assert on the client's auto-ack behavior without a real server.
  final List<(String, List<String>, String)> receiptAcks = [];

  @override
  Future<void> ackReceipts(String roomId, List<String> messageIds, String status) async {
    if (messageIds.isEmpty) return;
    receiptAcks.add((roomId, List.of(messageIds), status));
  }

  @override
  Future<String> mintLiveKitToken(String roomId) async => 'fake-token';

  final Map<String, List<int>> mediaBytesById = {};
  int _nextMediaId = 1;

  @override
  Future<ApiMessage> uploadMedia(
    String roomId, {
    required List<int> bytes,
    required String filename,
    required String contentType,
    required String kind,
    String? replyToMessageId,
  }) async {
    final mediaId = 'media-${_nextMediaId++}';
    mediaBytesById[mediaId] = bytes;
    final message = ApiMessage(
      id: 'msg-${_nextMessageId++}',
      roomId: roomId,
      senderId: me.id,
      kind: kind,
      mediaId: mediaId,
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      replyTo: replyToMessageId != null ? _snippetFor(replyToMessageId) : null,
    );
    messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(message))) as Map<String, dynamic>));
    return message;
  }

  @override
  Future<List<int>> downloadMedia(String mediaId) async {
    final bytes = mediaBytesById[mediaId];
    if (bytes == null) throw ApiException(404, 'not found');
    return bytes;
  }

  @override
  Future<void> deleteMedia(String mediaId) async {
    mediaBytesById.remove(mediaId);
    for (final entry in messagesByRoom.entries) {
      final matches = entry.value.where((m) => m.mediaId == mediaId);
      if (matches.isEmpty) continue;
      final message = matches.first;
      entry.value.removeWhere((m) => m.mediaId == mediaId);
      ws.emit(WsEvent('message.deleted', {'messageId': message.id, 'roomId': message.roomId}));
      return;
    }
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    for (final entry in messagesByRoom.entries) {
      final matches = entry.value.where((m) => m.id == messageId);
      if (matches.isEmpty) continue;
      final message = matches.first;
      entry.value.removeWhere((m) => m.id == messageId);
      ws.emit(WsEvent('message.deleted', {'messageId': message.id, 'roomId': message.roomId}));
      return;
    }
  }

  @override
  String mediaUrl(String mediaId) => 'fake://media/$mediaId';

  int _nextLocationMessageId = 1;

  @override
  Future<ApiMessage> shareLocation(String roomId, {required double lat, required double lng, required Duration ttl}) async {
    final message = ApiMessage(
      id: 'loc-${_nextLocationMessageId++}',
      roomId: roomId,
      senderId: me.id,
      kind: 'location',
      createdAt: DateTime.now(),
      location: ApiLocationShare(lat: lat, lng: lng, expiresAt: DateTime.now().add(ttl)),
    );
    messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(message))) as Map<String, dynamic>));
    return message;
  }

  @override
  Future<ApiMessage> updateLocation(String messageId, {required double lat, required double lng}) async {
    for (final entry in messagesByRoom.entries) {
      final index = entry.value.indexWhere((m) => m.id == messageId);
      if (index == -1) continue;
      final existing = entry.value[index];
      final updated = existing.copyWith(
        location: ApiLocationShare(lat: lat, lng: lng, expiresAt: existing.location!.expiresAt, endedAt: existing.location!.endedAt),
      );
      entry.value[index] = updated;
      ws.emit(WsEvent('message.updated', jsonDecode(jsonEncode(_messageJson(updated))) as Map<String, dynamic>));
      return updated;
    }
    throw ApiException(404, 'not found');
  }

  @override
  Future<ApiMessage> endLocationShare(String messageId) async {
    for (final entry in messagesByRoom.entries) {
      final index = entry.value.indexWhere((m) => m.id == messageId);
      if (index == -1) continue;
      final existing = entry.value[index];
      final updated = existing.copyWith(
        location: ApiLocationShare(
          lat: existing.location!.lat,
          lng: existing.location!.lng,
          expiresAt: existing.location!.expiresAt,
          endedAt: existing.location!.endedAt ?? DateTime.now(),
        ),
      );
      entry.value[index] = updated;
      ws.emit(WsEvent('message.updated', jsonDecode(jsonEncode(_messageJson(updated))) as Map<String, dynamic>));
      return updated;
    }
    throw ApiException(404, 'not found');
  }

  int _nextCallMessageId = 1;

  @override
  Future<ApiMessage> startCall(String roomId) async {
    final message = ApiMessage(
      id: 'callmsg-$_nextCallMessageId',
      roomId: roomId,
      senderId: me.id,
      kind: 'call',
      createdAt: DateTime.now(),
      call: ApiCall(id: 'call-${_nextCallMessageId++}', status: 'ringing', startedAt: DateTime.now()),
    );
    messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(message))) as Map<String, dynamic>));
    return message;
  }

  /// Records of every acceptCall/declineCall/leaveCall call, so tests can
  /// assert on which action a widget took without inspecting call status
  /// alone (accept doesn't change the fake's call status, matching the
  /// real server's "LiveKit's own join event is what others observe").
  final List<(String action, String callId)> callActions = [];

  @override
  Future<void> acceptCall(String callId) async {
    callActions.add(('accept', callId));
  }

  @override
  Future<void> declineCall(String callId) async {
    callActions.add(('decline', callId));
    _finalizeCall(callId, 'declined');
  }

  @override
  Future<void> leaveCall(String callId) async {
    callActions.add(('leave', callId));
    _finalizeCall(callId, 'missed');
  }

  void _finalizeCall(String callId, String status) {
    for (final entry in messagesByRoom.entries) {
      final index = entry.value.indexWhere((m) => m.call?.id == callId);
      if (index == -1) continue;
      final existing = entry.value[index];
      final updated = existing.copyWith(
        call: ApiCall(id: existing.call!.id, status: status, startedAt: existing.call!.startedAt, endedAt: DateTime.now()),
      );
      entry.value[index] = updated;
      ws.emit(WsEvent('message.updated', jsonDecode(jsonEncode(_messageJson(updated))) as Map<String, dynamic>));
      return;
    }
  }

  Map<String, dynamic> _messageJson(ApiMessage m) => {
        'id': m.id,
        'roomId': m.roomId,
        'senderId': m.senderId,
        'kind': m.kind,
        'body': m.body,
        'mediaId': m.mediaId,
        'createdAt': m.createdAt.toIso8601String(),
        'editedAt': m.editedAt?.toIso8601String(),
        'replyToMessageId': m.replyToMessageId,
        'replyTo': m.replyTo == null
            ? null
            : {
                'id': m.replyTo!.id,
                'senderId': m.replyTo!.senderId,
                'kind': m.replyTo!.kind,
                'body': m.replyTo!.body,
                'mediaId': m.replyTo!.mediaId,
              },
        'forwarded': m.forwarded,
        'status': m.status,
        'location': m.location == null
            ? null
            : {
                'lat': m.location!.lat,
                'lng': m.location!.lng,
                'expiresAt': m.location!.expiresAt.toIso8601String(),
                'endedAt': m.location!.endedAt?.toIso8601String(),
              },
        'call': m.call == null
            ? null
            : {
                'id': m.call!.id,
                'status': m.call!.status,
                'startedAt': m.call!.startedAt.toIso8601String(),
                'endedAt': m.call!.endedAt?.toIso8601String(),
              },
      };
}

class FakeWsClient extends WsClient {
  final _controller = StreamController<WsEvent>.broadcast();

  @override
  void connect() {
    // No real socket in tests; nothing to do.
  }

  @override
  Stream<WsEvent> get events => _controller.stream;

  void emit(WsEvent event) => _controller.add(event);

  /// Records every sendTyping call (roomId, isTyping) so tests can assert
  /// on the composer's typing-signal behavior without a real socket.
  final List<(String, bool)> typingSent = [];

  @override
  void sendTyping(String roomId, bool isTyping) {
    typingSent.add((roomId, isTyping));
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

/// A controllable stand-in for LocationService (FR3.*), so
/// LocationShareController can be tested without real GPS or platform
/// permission dialogs. [emit] pushes a fake position; [permissionDenied] and
/// [deniedForever] let a test simulate the user refusing access.
class FakeLocationService implements LocationService {
  bool permissionDenied = false;
  bool deniedForever = false;
  int requestPermissionCalls = 0;
  Position initialPosition = testPosition(0, 0);
  final _positionController = StreamController<Position>.broadcast();
  bool watching = false;

  /// Builds a Position fixture — public so tests can also use it to set
  /// [initialPosition] before calling start().
  static Position testPosition(double lat, double lng) => Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  @override
  Future<void> requestPermission() async {
    requestPermissionCalls++;
    if (deniedForever) throw const LocationPermissionDeniedException(true);
    if (permissionDenied) throw const LocationPermissionDeniedException(false);
  }

  @override
  Future<Position> getCurrentPosition() async => initialPosition;

  @override
  Stream<Position> watchPosition({int distanceFilterMeters = 30}) {
    watching = true;
    return _positionController.stream;
  }

  void emit(double lat, double lng) => _positionController.add(testPosition(lat, lng));

  void dispose() => _positionController.close();
}
