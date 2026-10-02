import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../data/api_config.dart';
import 'push_crypto.dart';

/// What a message notification says when its preview can't be decrypted —
/// the same text the server sends devices without a key.
const genericMessageBody = 'Sent a message in Roost';

/// A message notification as Android shows it (iOS shows the server's own,
/// rewritten by the notification service extension).
class MessageNotificationContent {
  const MessageNotificationContent({
    required this.title,
    required this.body,
    required this.roomId,
    this.senderId,
    this.senderAvatarMediaId,
  });

  final String title;
  final String body;
  final String roomId;
  final String? senderId;

  /// The sender's profile picture, to show instead of the app icon.
  final String? senderAvatarMediaId;
}

/// What to show for a message notification's [data] (see the server's
/// BuildMessageNotification): the sender as title and the decrypted preview
/// as body, or the generic text when [keyPair] is missing or the preview
/// won't decrypt. Null when it isn't a message notification for a chat.
Future<MessageNotificationContent?> messageNotificationContent(
  Map<String, dynamic> data, {
  required SimpleKeyPair? keyPair,
}) async {
  final roomId = data['roomId'] as String?;
  if (data['type'] != 'message' || roomId == null || roomId.isEmpty) return null;
  final preview = keyPair == null
      ? null
      : await decryptPushPreview(
          deviceKeyPair: keyPair,
          scheme: data['scheme'] as String?,
          ephemeralPublicKey: data['ephemeralPublicKey'] as String?,
          ciphertext: data['ciphertext'] as String?,
        );
  final sender = data['senderName'] as String?;
  final avatar = data['senderAvatarMediaId'] as String?;
  return MessageNotificationContent(
    title: (sender == null || sender.isEmpty) ? 'New message' : sender,
    body: (preview == null || preview.isEmpty) ? genericMessageBody : preview,
    roomId: roomId,
    senderId: data['senderId'] as String?,
    senderAvatarMediaId: (avatar == null || avatar.isEmpty) ? null : avatar,
  );
}

/// Loads a sender's profile picture by its media id, or returns null.
typedef SenderAvatarLoader = Future<Uint8List?> Function(String mediaId);

/// How long a notification waits for the sender's picture before it's
/// shown without one.
const senderAvatarTimeout = Duration(seconds: 8);

/// The sender's profile picture, fetched from the chat server over the
/// tailnet — only its id comes through push. The same small preview the
/// chat list shows. Null if it can't be had in time; never throws, like the
/// rest of this background-isolate path.
Future<Uint8List?> fetchSenderAvatar(String mediaId, {http.Client? client, String baseUrl = apiBaseUrl}) async {
  // Media ids are UUIDs; anything else never makes it into a URL.
  if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(mediaId)) return null;
  final c = client ?? http.Client();
  try {
    final response =
        await c.get(Uri.parse('$baseUrl/api/media/$mediaId?variant=preview')).timeout(senderAvatarTimeout);
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
    return response.bodyBytes;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// The Android notification for [content]: with the sender's picture, when
/// there is one, as the notification's icon and as a conversation from
/// that person; otherwise the plain notification.
NotificationDetails messageNotificationDetails(MessageNotificationContent content, {Uint8List? avatar}) {
  if (avatar == null) return const NotificationDetails(android: messagesChannel);
  final sender = Person(key: content.senderId, name: content.title, icon: ByteArrayAndroidIcon(avatar));
  return NotificationDetails(
    android: AndroidNotificationDetails(
      messagesChannel.channelId,
      messagesChannel.channelName,
      channelDescription: messagesChannel.channelDescription,
      importance: messagesChannel.importance,
      priority: messagesChannel.priority,
      category: AndroidNotificationCategory.message,
      largeIcon: ByteArrayAndroidBitmap(avatar),
      styleInformation: MessagingStyleInformation(
        const Person(name: 'You'),
        messages: [Message(content.body, DateTime.now(), sender)],
      ),
    ),
  );
}

/// Android's notification channel for new messages.
const messagesChannel = AndroidNotificationDetails(
  'messages',
  'Messages',
  channelDescription: 'New messages in your chats',
  importance: Importance.high,
  priority: Priority.high,
);

/// Shows (or, for the same chat, updates) the notification for a new
/// message on Android — one per chat, like the iOS thread grouping — with
/// the sender's profile picture when they have one. The chat's id is the
/// payload a tap routes on (see PushService).
Future<void> showMessageNotification(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data, {
  required SimpleKeyPair? keyPair,
  SenderAvatarLoader loadAvatar = fetchSenderAvatar,
}) async {
  final content = await messageNotificationContent(data, keyPair: keyPair);
  if (content == null) return;
  final avatarId = content.senderAvatarMediaId;
  final avatar = avatarId == null ? null : await loadAvatar(avatarId);
  await plugin.show(
    id: content.roomId.hashCode,
    title: content.title,
    body: content.body,
    notificationDetails: messageNotificationDetails(content, avatar: avatar),
    payload: content.roomId,
  );
}

/// The Android device key pair, or null when it can't be read (then the
/// generic text is shown). Separate from loadOrCreateDeviceKeyPair: a push
/// arriving must never create a new key, which would fail to decrypt
/// anyway and replace the registered one.
Future<SimpleKeyPair?> storedDeviceKeyPair(FlutterSecureStorage storage) async {
  try {
    final stored = await storage.read(key: pushPrivateKeyStorageKey);
    return stored == null ? null : await X25519().newKeyPairFromSeed(base64Decode(stored));
  } catch (_) {
    return null;
  }
}
