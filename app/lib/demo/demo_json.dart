import '../data/api_models.dart';

/// Serializes [m] into the same JSON shape the chat server sends for a
/// message — what [ApiMessage.fromJson] reads back. Used by the in-app demo
/// backend (and the test fakes) to emit WebSocket events exactly as the real
/// server would.
Map<String, dynamic> messageToJson(ApiMessage m) => {
      'id': m.id,
      'roomId': m.roomId,
      'senderId': m.senderId,
      'kind': m.kind,
      'body': m.body,
      'mediaId': m.mediaId,
      'createdAt': m.createdAt.toIso8601String(),
      'editedAt': m.editedAt?.toIso8601String(),
      'reactions': [
        for (final r in m.reactions) {'emoji': r.emoji, 'count': r.count, 'reactedByMe': r.reactedByMe},
      ],
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
      'deletedAt': m.deletedAt?.toIso8601String(),
      'status': m.status,
      'location': m.location == null
          ? null
          : {
              'lat': m.location!.lat,
              'lng': m.location!.lng,
              'expiresAt': m.location!.expiresAt.toIso8601String(),
              'endedAt': m.location!.endedAt?.toIso8601String(),
              'snapshotMediaId': m.location!.snapshotMediaId,
            },
      'call': m.call == null
          ? null
          : {
              'id': m.call!.id,
              'status': m.call!.status,
              'startedAt': m.call!.startedAt.toIso8601String(),
              'endedAt': m.call!.endedAt?.toIso8601String(),
              'answeredAt': m.call!.answeredAt?.toIso8601String(),
            },
      'media': m.media == null ? null : {'width': m.media!.width, 'height': m.media!.height},
    };
