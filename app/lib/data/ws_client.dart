import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_config.dart';
import 'api_models.dart';

/// A decoded event from the server's WebSocket hub (server/internal/ws) —
/// currently just `message.created`, broadcast to every member of the room
/// a new message lands in.
class WsEvent {
  const WsEvent(this.type, this.payload);
  final String type;
  final Map<String, dynamic> payload;
}

/// Wraps the single /ws connection the app holds for the lifetime it's
/// running, per the "signaling over one WebSocket" design in
/// docs/architecture-overview.md. Reconnects with backoff on drop — mobile
/// clients lose and regain network constantly.
class WsClient {
  WsClient({String? baseUrl}) : _baseUrl = baseUrl ?? wsBaseUrl;

  /// Emitted locally (never sent by the server) each time the socket
  /// connects or reconnects. Anything broadcast while it was down — e.g. a
  /// message that arrived as a push notification while the app was
  /// suspended — never reaches this client over the socket, so listeners
  /// re-fetch their state on this event.
  static const connectedEvent = 'connection.ready';

  final String _baseUrl;
  final _controller = StreamController<WsEvent>.broadcast();
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _closed = false;

  Stream<WsEvent> get events => _controller.stream;

  void connect() {
    _closed = false;
    _connectOnce();
  }

  void _connectOnce() {
    final channel = WebSocketChannel.connect(Uri.parse('$_baseUrl/ws'));
    _channel = channel;
    // A channel replaced by reconnectNow() still reports its own close —
    // it must not schedule a reconnect of its own on top of the new one.
    bool current() => identical(_channel, channel);

    // channel.stream's onError doesn't reliably catch a failure to
    // establish the connection in the first place (e.g. the server isn't
    // up yet) — that surfaces through `ready` instead. Without this, a
    // refused connection prints as an unhandled exception instead of
    // quietly triggering a reconnect.
    channel.ready.then((_) {
      if (current() && !_controller.isClosed) _controller.add(const WsEvent(connectedEvent, {}));
    }).catchError((Object _) {
      if (current()) _scheduleReconnect();
    });

    channel.stream.listen(
      (raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        _controller.add(WsEvent(decoded['type'] as String, decoded['payload'] as Map<String, dynamic>? ?? const {}));
      },
      onError: (Object _) {
        if (current()) _scheduleReconnect();
      },
      onDone: () {
        if (current()) _scheduleReconnect();
      },
      cancelOnError: true,
    );
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connectOnce);
  }

  /// Drops the current connection and opens a fresh one right away. Called
  /// when the app returns to the foreground: iOS suspends a backgrounded
  /// app, and the socket it had may be dead without either side having
  /// noticed yet — the server has meanwhile been sending pushes instead.
  /// The fresh connection's [connectedEvent] then triggers the catch-up.
  void reconnectNow() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    final old = _channel;
    _channel = null;
    old?.sink.close();
    _connectOnce();
  }

  ApiMessage? messageFrom(WsEvent event) {
    if (event.type != 'message.created' && event.type != 'message.updated') return null;
    return ApiMessage.fromJson(event.payload);
  }

  /// Sends a typing signal to the server (FR1.7) — the one client->server
  /// message this socket carries; everything else is server->client
  /// fan-out. Best-effort: a dropped/reconnecting socket just means this
  /// particular ping doesn't reach the room, not a failure worth surfacing.
  void sendTyping(String roomId, bool isTyping) {
    try {
      _channel?.sink.add(jsonEncode({
        'type': isTyping ? 'typing.start' : 'typing.stop',
        'payload': {'roomId': roomId},
      }));
    } catch (_) {
      // Ignored — see doc comment above.
    }
  }

  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}
