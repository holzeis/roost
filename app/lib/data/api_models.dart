/// Raw DTOs decoded straight from the chat server's JSON (see
/// server/internal/models and server/internal/api's response shapes).
/// Kept separate from the UI-flavored types in models.dart, which add
/// display formatting (relative time labels, avatar initials) on top.
library;

class ApiUser {
  const ApiUser({required this.id, required this.displayName, this.avatarMediaId});

  factory ApiUser.fromJson(Map<String, dynamic> json) => ApiUser(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        avatarMediaId: json['avatarMediaId'] as String?,
      );

  final String id;
  final String displayName;
  final String? avatarMediaId;
}

class ApiContact {
  const ApiContact({required this.id, required this.displayName, required this.online});

  factory ApiContact.fromJson(Map<String, dynamic> json) => ApiContact(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        online: json['online'] as bool? ?? false,
      );

  final String id;
  final String displayName;
  final bool online;
}

class ApiRoom {
  const ApiRoom({
    required this.id,
    this.name,
    required this.isGroup,
    required this.createdBy,
    required this.createdAt,
    this.members = const [],
    this.lastMessageBody,
    this.lastMessageKind,
    this.lastMessageAt,
  });

  factory ApiRoom.fromJson(Map<String, dynamic> json) => ApiRoom(
        id: json['id'] as String,
        name: json['name'] as String?,
        isGroup: json['isGroup'] as bool? ?? false,
        createdBy: json['createdBy'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        members: (json['members'] as List<dynamic>?)?.cast<String>() ?? const [],
        lastMessageBody: json['lastMessageBody'] as String?,
        lastMessageKind: json['lastMessageKind'] as String?,
        lastMessageAt: json['lastMessageAt'] != null ? DateTime.parse(json['lastMessageAt'] as String) : null,
      );

  final String id;
  final String? name;
  final bool isGroup;
  final String createdBy;
  final DateTime createdAt;
  final List<String> members;
  final String? lastMessageBody;
  final String? lastMessageKind;
  final DateTime? lastMessageAt;
}

class ApiMessage {
  const ApiMessage({
    required this.id,
    required this.roomId,
    required this.senderId,
    required this.kind,
    this.body,
    this.mediaId,
    required this.createdAt,
  });

  factory ApiMessage.fromJson(Map<String, dynamic> json) => ApiMessage(
        id: json['id'] as String,
        roomId: json['roomId'] as String,
        senderId: json['senderId'] as String,
        kind: json['kind'] as String,
        body: json['body'] as String?,
        mediaId: json['mediaId'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  final String id;
  final String roomId;
  final String senderId;
  final String kind;
  final String? body;
  final String? mediaId;
  final DateTime createdAt;
}
