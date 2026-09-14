import 'dart:async';
import 'dart:convert';

import 'package:roost/data/api_client.dart';
import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';

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
  Future<ApiMessage> sendTextMessage(String roomId, String body) async {
    final message = ApiMessage(
      id: 'msg-${_nextMessageId++}',
      roomId: roomId,
      senderId: me.id,
      kind: 'text',
      body: body,
      createdAt: DateTime.now(),
    );
    messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    ws.emit(WsEvent('message.created', jsonDecode(jsonEncode(_messageJson(message))) as Map<String, dynamic>));
    return message;
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

  @override
  Future<String> mintLiveKitToken(String roomId) async => 'fake-token';

  Map<String, dynamic> _messageJson(ApiMessage m) => {
        'id': m.id,
        'roomId': m.roomId,
        'senderId': m.senderId,
        'kind': m.kind,
        'body': m.body,
        'mediaId': m.mediaId,
        'createdAt': m.createdAt.toIso8601String(),
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

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}
