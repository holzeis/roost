import UserNotifications

/// Decrypts a message notification's preview before iOS shows it (FR5.2).
/// The server sends the notification with generic text, "mutable-content",
/// and the preview encrypted to this device's key (see
/// server/internal/push's BuildMessageNotification); this swaps the
/// decrypted text in. If anything goes wrong — no key, an unexpected
/// payload — the notification simply shows as sent. Kept small: extensions
/// run under a tight memory limit.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    self.contentHandler = contentHandler
    bestAttempt = content

    let info = request.content.userInfo
    // One notification thread per chat.
    if let roomId = info["roomId"] as? String {
      content.threadIdentifier = roomId
    }
    if let key = PushKeyStore.loadPrivateKey(),
      let preview = try? PushCrypto.open(
        privateKey: key,
        scheme: info["scheme"] as? String,
        ephemeralPublicKey: info["ephemeralPublicKey"] as? String,
        ciphertext: info["ciphertext"] as? String)
    {
      content.body = preview
    }
    contentHandler(content)
  }

  /// iOS is about to give up on the extension: show what we have.
  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttempt {
      contentHandler(bestAttempt)
    }
  }
}
