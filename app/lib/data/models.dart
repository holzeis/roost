/// Client-side domain models. Field names mirror the JSON the chat server
/// returns (see server/internal/models) so a future API client can decode
/// straight into these.
library;

enum MessageKind { text, image, video, location, call }

class RoomSummary {
  const RoomSummary({
    required this.id,
    required this.name,
    required this.initial,
    required this.lastMessagePreview,
    required this.lastActivityLabel,
    this.unreadCount = 0,
    this.isGroup = false,
  });

  final String id;
  final String name;
  final String initial;
  final String lastMessagePreview;
  final String lastActivityLabel;
  final int unreadCount;
  final bool isGroup;
}

enum PresenceStatus { online, lastSeen }

class Contact {
  const Contact({
    required this.id,
    required this.displayName,
    required this.initial,
    required this.presence,
    this.lastSeenLabel,
  });

  final String id;
  final String displayName;
  final String initial;
  final PresenceStatus presence;
  final String? lastSeenLabel;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderName,
    required this.kind,
    required this.timeLabel,
    this.body,
    this.fromMe = false,
  });

  final String id;
  final String senderName;
  final MessageKind kind;
  final String timeLabel;
  final String? body;
  final bool fromMe;
}
