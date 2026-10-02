import CryptoKit
import Foundation

/// Decrypts message-notification previews (FR5.2): the Swift counterpart of
/// server/internal/cryptobox (the reference) and the app's
/// lib/services/push_crypto.dart — an X25519 + HKDF-SHA256 +
/// ChaCha20-Poly1305 sealed box to this device's key, with a fixed all-zero
/// nonce (safe: the key is unique per message). All three are checked
/// against server/internal/cryptobox/testdata/push_vector.json. To check
/// this one locally, compile it with a small main.swift that loads the
/// vector and calls open(...), e.g.
///   swiftc PushCrypto.swift main.swift -o kat && ./kat push_vector.json
enum PushCrypto {
  static let scheme = "v1"
  private static let domain = Data("roost-push-v1".utf8)

  enum Failure: Error {
    case unsupportedScheme, malformed, notUTF8
  }

  /// The preview, decrypted with this device's private key. Throws on
  /// anything unexpected; the caller then shows the generic text.
  static func open(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    scheme: String?,
    ephemeralPublicKey: String?,
    ciphertext: String?
  ) throws -> String {
    guard scheme == Self.scheme else { throw Failure.unsupportedScheme }
    guard let ephemeralB64 = ephemeralPublicKey, let ephemeralRaw = Data(base64Encoded: ephemeralB64),
      let ciphertextB64 = ciphertext, let sealed = Data(base64Encoded: ciphertextB64), sealed.count >= 16
    else { throw Failure.malformed }

    let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
    // Info binds both public keys and the domain, as on the server.
    let info = ephemeralRaw + privateKey.publicKey.rawRepresentation + domain
    let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    // ChaChaPoly's "combined" form is nonce ‖ ciphertext ‖ tag; the server
    // sends ciphertext ‖ tag with an implicit all-zero nonce.
    let box = try ChaChaPoly.SealedBox(combined: Data(count: 12) + sealed)
    let plain = try ChaChaPoly.open(box, using: key)
    guard let text = String(data: plain, encoding: .utf8) else { throw Failure.notUTF8 }
    return text
  }
}
