import 'dart:convert';

import 'package:http/http.dart' as http;

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

  Future<List<ApiContact>> listUsers() async {
    final res = await _http.get(_uri('/api/users'));
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ApiContact.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ApiRoom>> listRooms() async {
    final res = await _http.get(_uri('/api/rooms'));
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ApiRoom.fromJson(e as Map<String, dynamic>))
        .toList();
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
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ApiMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ApiMessage> sendTextMessage(String roomId, String body) async {
    final res = await _http.post(
      _uri('/api/rooms/$roomId/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'body': body}),
    );
    _checkOk(res);
    return ApiMessage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<ApiMessage>> searchMessages(String roomId, String query) async {
    final res = await _http.get(_uri('/api/rooms/$roomId/search', {'q': query}));
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ApiMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addReaction(String messageId, String emoji) async {
    final res = await _http.put(_uri('/api/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}'));
    _checkOk(res);
  }

  Future<void> removeReaction(String messageId, String emoji) async {
    final res = await _http.delete(_uri('/api/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}'));
    _checkOk(res);
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
