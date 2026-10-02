import UserNotifications

/// Prepares a message notification before iOS shows it. The server sends
/// it with generic text, "mutable-content", the preview encrypted to this
/// device's key, and the sender's avatar id (see server/internal/push's
/// BuildMessageNotification); this swaps the decrypted text in (FR5.2) and
/// shows the sender's profile picture instead of the app icon (see
/// SenderAvatar). If anything goes wrong — no key, an unexpected payload,
/// an unreachable server — the notification shows with what it has. Kept
/// small: extensions run under a tight memory limit.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?
  private let lock = NSLock()

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
    let roomId = info["roomId"] as? String
    // One notification thread per chat.
    if let roomId {
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

    guard let roomId, let senderId = info["senderId"] as? String, !senderId.isEmpty,
      let mediaId = info["senderAvatarMediaId"] as? String,
      let base = SharedSettings.apiBaseURL
    else {
      return deliver(content)
    }
    let senderName = (info["senderName"] as? String) ?? content.title
    SenderAvatar.load(mediaId: mediaId, base: base, cacheDirectory: SenderAvatar.cacheDirectory()) { image in
      guard let image else { return self.deliver(content) }
      self.deliver(
        SenderAvatar.communicationContent(
          content, senderId: senderId, senderName: senderName, roomId: roomId, image: image) ?? content)
    }
  }

  /// iOS is about to give up on the extension: show what we have.
  override func serviceExtensionTimeWillExpire() {
    if let bestAttempt {
      deliver(bestAttempt)
    }
  }

  /// Hands [content] to iOS — once: the avatar fetch and the timeout can
  /// race.
  private func deliver(_ content: UNNotificationContent) {
    lock.lock()
    let handler = contentHandler
    contentHandler = nil
    lock.unlock()
    handler?(content)
  }
}
