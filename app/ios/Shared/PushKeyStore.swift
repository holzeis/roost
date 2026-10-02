import CryptoKit
import Foundation
import Security

/// This device's key pair for end-to-end encrypted message previews in push
/// notifications (FR5.2), kept in the keychain. Compiled into both the app
/// (which creates the pair and registers the public key — see
/// AppDelegate's "roost/push_keys" channel) and the notification service
/// extension (which decrypts with the private key). They share the item
/// through the App Group, which doubles as a keychain access group.
///
/// Readable after the first unlock since boot: notifications usually arrive
/// while the phone is locked. "ThisDeviceOnly", so it's never restored onto
/// another phone from a backup — a new phone makes and registers its own.
enum PushKeyStore {
  static let accessGroup = "group.me.holzeis.roost.roost"
  private static let service = "me.holzeis.roost.push-key"
  private static let account = "v1"

  enum Failure: Error {
    case keychain(OSStatus)
  }

  private static var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrAccessGroup: accessGroup,
    ]
  }

  /// The stored private key, or nil if there's none (yet) or the keychain
  /// can't be read.
  static func loadPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
  }

  /// The public key to register (base64), creating and storing the pair the
  /// first time. Throws if it can't be stored where the extension can read
  /// it — then the app registers no key and gets generic notification text,
  /// rather than encrypted previews the extension couldn't open.
  static func publicKeyBase64() throws -> String {
    if let existing = loadPrivateKey() {
      return existing.publicKey.rawRepresentation.base64EncodedString()
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    var item = baseQuery
    item[kSecValueData] = key.rawRepresentation
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemDelete(baseQuery as CFDictionary)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure.keychain(status) }
    return key.publicKey.rawRepresentation.base64EncodedString()
  }
}
