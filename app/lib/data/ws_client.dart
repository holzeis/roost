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
    channel.stream.listen(
      (raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        _controller.add(WsEvent(decoded['type'] as String, decoded['payload'] as Map<String, dynamic>? ?? const {}));
      },
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connectOnce);
  }

  ApiMessage? messageFrom(WsEvent event) {
    if (event.type != 'message.created') return null;
    return ApiMessage.fromJson(event.payload);
  }

  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}
