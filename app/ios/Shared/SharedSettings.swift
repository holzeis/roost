import Foundation

/// Settings the app hands to its extensions through the App Group's shared
/// defaults. Compiled into both the app (which writes them — see
/// AppDelegate's "roost/push_keys" channel) and the notification service
/// extension (which reads them).
enum SharedSettings {
  private static let apiBaseURLKey = "apiBaseUrl"

  private static var defaults: UserDefaults? { UserDefaults(suiteName: PushKeyStore.accessGroup) }

  /// The chat server's address (the app's API_BASE_URL), so the
  /// notification service extension can fetch a sender's profile picture
  /// over the tailnet. Only http(s) URLs are kept.
  static var apiBaseURL: URL? {
    get { defaults?.string(forKey: apiBaseURLKey).flatMap(validURL) }
    set { defaults?.set(newValue?.absoluteString, forKey: apiBaseURLKey) }
  }

  static func validURL(_ string: String) -> URL? {
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host != nil
    else { return nil }
    return url
  }
}
