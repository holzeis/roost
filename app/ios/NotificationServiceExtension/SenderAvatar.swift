import Foundation
import Intents
import UserNotifications

/// Shows the sender's profile picture on a message notification instead of
/// the app icon: the server names the sender's avatar (senderAvatarMediaId,
/// see server/internal/push), this fetches it from the chat server over the
/// tailnet — the image never travels through Apple's push service — and
/// turns the notification into a Communication Notification (an incoming
/// INSendMessageIntent), which iOS draws with the sender's picture.
///
/// Avatars are cached by media id in the App Group's caches: a new picture
/// gets a new id, so a cached one never goes stale.
enum SenderAvatar {
  /// The extension has about 30 seconds in all; a slow server shouldn't
  /// hold the notification up for long.
  static let fetchTimeout: TimeInterval = 8

  /// Where the avatar with [mediaId] is served: the same small preview
  /// variant the app's chat list shows. Nil for anything but a UUID, so a
  /// payload can never point the request (or the cache path) elsewhere.
  static func url(base: URL, mediaId: String) -> URL? {
    guard UUID(uuidString: mediaId) != nil else { return nil }
    var components = URLComponents(
      url: base.appendingPathComponent("api/media/\(mediaId.lowercased())"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "variant", value: "preview")]
    return components?.url
  }

  static func cacheDirectory() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushKeyStore.accessGroup)?
      .appendingPathComponent("Library/Caches/notification-avatars", isDirectory: true)
  }

  /// The avatar's image data — from the cache, or fetched and cached — or
  /// nil if it can't be had. Calls [completion] exactly once.
  static func load(
    mediaId: String, base: URL, cacheDirectory: URL?, session: URLSession = .shared,
    completion: @escaping (Data?) -> Void
  ) {
    guard let url = url(base: base, mediaId: mediaId) else { return completion(nil) }
    let cached = cacheDirectory?.appendingPathComponent(mediaId.lowercased())
    if let cached, let data = try? Data(contentsOf: cached), !data.isEmpty {
      return completion(data)
    }
    var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    session.dataTask(with: request) { data, response, _ in
      guard let data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 else {
        return completion(nil)
      }
      if let cacheDirectory, let cached {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
      }
      completion(data)
    }.resume()
  }

  /// [content] as a Communication Notification from the sender, carrying
  /// their picture; nil if iOS won't make one (e.g. the app lacks the
  /// Communication Notifications entitlement), and the caller then shows
  /// [content] as it is.
  static func communicationContent(
    _ content: UNNotificationContent, senderId: String, senderName: String, roomId: String, image: Data
  ) -> UNNotificationContent? {
    let avatar = INImage(imageData: image)
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: senderName,
      image: avatar,
      contactIdentifier: nil,
      customIdentifier: senderId)
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: content.body,
      speakableGroupName: nil,
      conversationIdentifier: roomId,
      serviceName: nil,
      sender: sender,
      attachments: nil)
    intent.setImage(avatar, forParameterNamed: \.sender)

    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)
    return try? content.updating(from: intent)
  }
}
