import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'push_crypto.dart';

/// What a message notification says when its preview can't be decrypted —
/// the same text the server sends devices without a key.
const genericMessageBody = 'Sent a message in Roost';

/// A message notification as Android shows it (iOS shows the server's own,
/// rewritten by the notification service extension).
class MessageNotificationContent {
  const MessageNotificationContent({required this.title, required this.body, required this.roomId});

  final String title;
  final String body;
  final String roomId;
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
  return MessageNotificationContent(
    title: (sender == null || sender.isEmpty) ? 'New message' : sender,
    body: (preview == null || preview.isEmpty) ? genericMessageBody : preview,
    roomId: roomId,
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
/// message on Android — one per chat, like the iOS thread grouping. The
/// chat's id is the payload a tap routes on (see PushService).
Future<void> showMessageNotification(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data, {
  required SimpleKeyPair? keyPair,
}) async {
  final content = await messageNotificationContent(data, keyPair: keyPair);
  if (content == null) return;
  await plugin.show(
    id: content.roomId.hashCode,
    title: content.title,
    body: content.body,
    notificationDetails: const NotificationDetails(android: messagesChannel),
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
