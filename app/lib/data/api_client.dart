import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'api_config.dart';
import 'api_models.dart';

/// Thin REST client for the chat server. There's deliberately no auth header
/// here: per the architecture's "Tailscale identity instead of a custom auth
/// system" decision, identity is resolved from the network connection
/// itself (or the ENABLE_DEV_AUTH bypass in local dev) — the client has
/// nothing to prove.
class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? apiBaseUrl;

  final http.Client _http;
  final String _baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl$path').replace(queryParameters: query);

  Future<ApiUser> getMe() async {
    final res = await _http.get(_uri('/api/me'));
    _checkOk(res);
    return ApiUser.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ApiUser> updateMe({required String displayName, String? avatarMediaId}) async {
    final res = await _http.patch(
      _uri('/api/me'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'displayName': displayName, 'avatarMediaId': avatarMediaId}),
    );
    _checkOk(res);
    return ApiUser.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Sets the caller's own profile picture (FR6.4) — see
  /// server/internal/api's handleUploadAvatar. Unlike uploadMedia this is
  /// user-scoped, not room-scoped, and never creates a chat message.
  Future<ApiUser> uploadAvatar({
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/me/avatar'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType.parse(contentType)));
    final streamed = await _http.send(request);
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return ApiUser.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Registers this device's push token for FR5.1's call-wake fallback —
  /// see server/internal/api's handleRegisterDevice. Safe to call on every
  /// app start: the server treats re-registering the same token as a
  /// refresh, not an error.
  Future<void> registerDevice({required String platform, required String pushToken}) async {
    final res = await _http.post(
      _uri('/api/devices'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'platform': platform, 'pushToken': pushToken}),
    );
    _checkOk(res);
  }

  Future<List<ApiContact>> listUsers() async {
    final res = await _http.get(_uri('/api/users'));
    _checkOk(res);
    return _decodeList(res.body).map((e) => ApiContact.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ApiRoom>> listRooms() async {
    final res = await _http.get(_uri('/api/rooms'));
    _checkOk(res);
    return _decodeList(res.body).map((e) => ApiRoom.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ApiRoom> getRoom(String roomId) async {
    final res = await _http.get(_uri('/api/rooms/$roomId'));
    _checkOk(res);
    return ApiRoom.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ApiRoom> createRoom({String? name, required bool isGroup, required List<String> memberIds}) async {
    final res = await _http.post(
      _uri('/api/rooms'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'isGroup': isGroup, 'memberIds': memberIds}),
    );
    _checkOk(res);
    return ApiRoom.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<ApiMessage>> listMessages(String roomId, {DateTime? before, int limit = 50}) async {
    final res = await _http.get(_uri('/api/rooms/$roomId/messages', {
      if (before != null) 'before': before.toUtc().toIso8601String(),
      'limit': '$limit',
    }));
    _checkOk(res);
    return _decodeList(res.body).map((e) => ApiMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ApiMessage> sendTextMessage(String roomId, String body, {String? replyToMessageId}) async {
    final res = await _http.post(
      _uri('/api/rooms/$roomId/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'body': body, if (replyToMessageId != null) 'replyToMessageId': replyToMessageId}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Edits a text message's body (FR1.13) — the server enforces the
  /// sender-only, within-1-minute rule; this just surfaces its response/error.
  Future<ApiMessage> editMessage(String messageId, String body) async {
    final res = await _http.patch(
      _uri('/api/messages/$messageId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'body': body}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Forwards a message into another room (FR1.11). The server duplicates
  /// media rather than sharing the original file.
  Future<ApiMessage> forwardMessage(String messageId, String toRoomId) async {
    final res = await _http.post(
      _uri('/api/messages/$messageId/forward'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'roomId': toRoomId}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Fetches Open Graph metadata for a URL (FR1.14). Returns null rather
  /// than throwing on a 404 (no preview available) — that's an ordinary,
  /// expected outcome for most URLs, not an error worth surfacing.
  Future<ApiLinkPreview?> fetchLinkPreview(String url) async {
    final res = await _http.get(_uri('/api/link-preview', {'url': url}));
    if (res.statusCode == 404) return null;
    _checkOk(res);
    return ApiLinkPreview.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<ApiMessage>> searchMessages(String roomId, String query) async {
    final res = await _http.get(_uri('/api/rooms/$roomId/search', {'q': query}));
    _checkOk(res);
    return _decodeList(res.body).map((e) => ApiMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Uploads an image or video and creates the chat message for it in one
  /// call (FR2.1/2.2) — see server/internal/api's handleUploadMedia.
  Future<ApiMessage> uploadMedia(
    String roomId, {
    required List<int> bytes,
    required String filename,
    required String contentType,
    required String kind,
    String? replyToMessageId,
    String? caption,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/rooms/$roomId/media'))
      ..fields['kind'] = kind
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType.parse(contentType)));
    if (replyToMessageId != null) request.fields['replyToMessageId'] = replyToMessageId;
    // FR2.6: an optional caption shown under the photo/video, same as a
    // text message's own body.
    if (caption != null && caption.isNotEmpty) request.fields['caption'] = caption;
    final streamed = await _http.send(request);
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Downloads a media object's raw bytes (FR2.3: viewed inline or
  /// downloaded — this backs both, the app decides what to do with them).
  Future<List<int>> downloadMedia(String mediaId) async {
    final res = await _http.get(_uri('/api/media/$mediaId'));
    _checkOk(res);
    return res.bodyBytes;
  }

  Future<void> deleteMedia(String mediaId) async {
    final res = await _http.delete(_uri('/api/media/$mediaId'));
    _checkOk(res);
  }

  /// Deletes a non-media message (FR1.15) — image/video messages go through
  /// [deleteMedia] instead, which also removes the underlying file.
  Future<void> deleteMessage(String messageId) async {
    final res = await _http.delete(_uri('/api/messages/$messageId'));
    _checkOk(res);
  }

  /// The URL a widget can load a media object's bytes from directly (e.g.
  /// Image.network) — same endpoint as downloadMedia, just not fetched here.
  String mediaUrl(String mediaId) => '$_baseUrl/api/media/$mediaId';

  Future<void> addReaction(String messageId, String emoji) async {
    final res = await _http.put(_uri('/api/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}'));
    _checkOk(res);
  }

  Future<void> removeReaction(String messageId, String emoji) async {
    final res = await _http.delete(_uri('/api/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}'));
    _checkOk(res);
  }

  /// Acks a batch of messages in roomId as delivered or seen (FR1.5,
  /// FR1.6) — status is 'delivered' or 'seen'. The server records the
  /// caller's own receipt and broadcasts an updated message.status event to
  /// the room over the WebSocket if that moves the message's overall status.
  Future<void> ackReceipts(String roomId, List<String> messageIds, String status) async {
    if (messageIds.isEmpty) return;
    final res = await _http.post(
      _uri('/api/rooms/$roomId/receipts'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'messageIds': messageIds, 'status': status}),
    );
    _checkOk(res);
  }

  /// Starts a live location share in roomId (FR3.1/FR3.2). ttl is the
  /// sender-chosen duration from a small preset set; the server validates
  /// it's within a sane range.
  Future<ApiMessage> shareLocation(String roomId, {required double lat, required double lng, required Duration ttl}) async {
    final res = await _http.post(
      _uri('/api/rooms/$roomId/location'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'lat': lat, 'lng': lng, 'ttlSeconds': ttl.inSeconds}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Posts the sender's latest position for an active share (FR3.3).
  Future<ApiMessage> updateLocation(String messageId, {required double lat, required double lng}) async {
    final res = await _http.patch(
      _uri('/api/messages/$messageId/location'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'lat': lat, 'lng': lng}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Ends an active share before its TTL elapses (FR3.5).
  Future<ApiMessage> endLocationShare(String messageId) async {
    final res = await _http.post(_uri('/api/messages/$messageId/location/end'));
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<String> mintLiveKitToken(String roomId) async {
    final res = await _http.post(
      _uri('/api/livekit/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'roomId': roomId}),
    );
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
  }

  /// Starts a call in roomId (FR4.1/FR4.2), ringing every other member.
  Future<ApiMessage> startCall(String roomId) async {
    final res = await _http.post(_uri('/api/rooms/$roomId/calls'));
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Joins an active call (FR4.5).
  Future<void> acceptCall(String callId) async {
    final res = await _http.post(_uri('/api/calls/$callId/accept'));
    _checkOk(res);
  }

  /// Declines a call (FR4.5) — ends it immediately in a 1:1 room, a no-op
  /// on the call record in a group room (other invitees may still answer).
  Future<void> declineCall(String callId) async {
    final res = await _http.post(_uri('/api/calls/$callId/decline'));
    _checkOk(res);
  }

  /// Leaves/ends a call (FR4.5) — the same action whether hanging up
  /// mid-call or giving up on an unanswered one.
  Future<void> leaveCall(String callId) async {
    final res = await _http.post(_uri('/api/calls/$callId/leave'));
    _checkOk(res);
  }

  /// Go marshals a nil slice as JSON `null`, not `[]` — an empty list
  /// response (e.g. a brand-new user with no rooms yet) decodes to Dart
  /// `null`, which `as List<dynamic>` doesn't accept. The server also
  /// initializes its slices to avoid ever sending `null` here, but this
  /// stays defensive rather than relying on that alone.
  List<dynamic> _decodeList(String body) => (jsonDecode(body) as List<dynamic>?) ?? const [];

  void _checkOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, res.body);
    }
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}
