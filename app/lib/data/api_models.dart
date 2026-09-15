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
    this.editedAt,
    this.reactions = const [],
    this.replyToMessageId,
    this.replyTo,
    this.forwarded = false,
    this.status = 'sent',
  });

  factory ApiMessage.fromJson(Map<String, dynamic> json) => ApiMessage(
        id: json['id'] as String,
        roomId: json['roomId'] as String,
        senderId: json['senderId'] as String,
        kind: json['kind'] as String,
        body: json['body'] as String?,
        mediaId: json['mediaId'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        editedAt: json['editedAt'] != null ? DateTime.parse(json['editedAt'] as String) : null,
        reactions: (json['reactions'] as List<dynamic>?)
                ?.map((e) => ApiReaction.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        replyToMessageId: json['replyToMessageId'] as String?,
        replyTo: json['replyTo'] != null
            ? ApiMessageSnippet.fromJson(json['replyTo'] as Map<String, dynamic>)
            : null,
        forwarded: json['forwarded'] as bool? ?? false,
        // Absent means no recipient has acked yet (FR1.5/FR1.6) — the
        // server omits the field via `omitempty` rather than sending "sent".
        status: json['status'] as String? ?? 'sent',
      );

  final String id;
  final String roomId;
  final String senderId;
  final String kind;
  final String? body;
  final String? mediaId;
  final DateTime createdAt;
  final DateTime? editedAt;
  final List<ApiReaction> reactions;
  final String? replyToMessageId;
  final ApiMessageSnippet? replyTo;
  final bool forwarded;
  /// 'sent' | 'delivered' | 'seen' (FR1.5, FR1.6). Only meaningful for a
  /// message sent by the current user — recipients ignore it.
  final String status;

  ApiMessage copyWith({List<ApiReaction>? reactions, String? body, DateTime? editedAt, String? status}) =>
      ApiMessage(
        id: id,
        roomId: roomId,
        senderId: senderId,
        kind: kind,
        body: body ?? this.body,
        mediaId: mediaId,
        createdAt: createdAt,
        editedAt: editedAt ?? this.editedAt,
        reactions: reactions ?? this.reactions,
        replyToMessageId: replyToMessageId,
        replyTo: replyTo,
        forwarded: forwarded,
        status: status ?? this.status,
      );
}

/// A trimmed preview of another message, embedded in a reply (FR1.10).
class ApiMessageSnippet {
  const ApiMessageSnippet({required this.id, required this.senderId, required this.kind, this.body});

  factory ApiMessageSnippet.fromJson(Map<String, dynamic> json) => ApiMessageSnippet(
        id: json['id'] as String,
        senderId: json['senderId'] as String,
        kind: json['kind'] as String,
        body: json['body'] as String?,
      );

  final String id;
  final String senderId;
  final String kind;
  final String? body;
}

class ApiReaction {
  const ApiReaction({required this.emoji, required this.count, required this.reactedByMe});

  factory ApiReaction.fromJson(Map<String, dynamic> json) => ApiReaction(
        emoji: json['emoji'] as String,
        count: json['count'] as int,
        reactedByMe: json['reactedByMe'] as bool? ?? false,
      );

  final String emoji;
  final int count;
  final bool reactedByMe;
}

/// Open Graph metadata for a URL found in a text message (FR1.14).
class ApiLinkPreview {
  const ApiLinkPreview({required this.url, this.title, this.description, this.imageUrl, this.siteName});

  factory ApiLinkPreview.fromJson(Map<String, dynamic> json) => ApiLinkPreview(
        url: json['url'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        imageUrl: json['imageUrl'] as String?,
        siteName: json['siteName'] as String?,
      );

  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
}
