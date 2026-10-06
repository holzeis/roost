import Flutter
import Intents

/// Tells iOS about a chat the user just sent to, so it's suggested in the
/// system share sheet with its picture (FR2.7; the Dart side is
/// lib/services/share_suggestions.dart). Replaces share_handler's own
/// donation on iOS, which passes the picture as a file URL inside Roost's
/// sandbox that the share sheet, running in another process, can't read.
/// Here the image data itself goes into the donation.
///
/// Channel "roost/share_suggestions", method "donate" with
/// {conversationIdentifier, name, imagePath?}.
enum ShareSuggestionDonor {
  static func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(name: "roost/share_suggestions", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { call, result in
        guard call.method == "donate", let args = call.arguments as? [String: Any],
          let id = args["conversationIdentifier"] as? String, let name = args["name"] as? String
        else { return result(FlutterMethodNotImplemented) }
        let image = (args["imagePath"] as? String).flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        // Answered right away: a suggestion is best-effort, and iOS's
        // donation can take its time (or never call back when the system
        // service isn't there), which mustn't hold up the Dart side.
        donate(conversationIdentifier: id, name: name, imageData: image) { _ in }
        result(nil)
      }
  }

  /// The intent iOS's share sheet builds its suggestion from: the chat's
  /// name, and its picture (the other person's, for a 1:1 chat) when there
  /// is one.
  static func intent(conversationIdentifier: String, name: String, imageData: Data?) -> INSendMessageIntent {
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: nil,
      speakableGroupName: INSpeakableString(spokenPhrase: name),
      conversationIdentifier: conversationIdentifier,
      serviceName: "Roost",
      sender: nil,
      attachments: nil)
    if let imageData, !imageData.isEmpty {
      intent.setImage(INImage(imageData: imageData), forParameterNamed: \.speakableGroupName)
    }
    return intent
  }

  static func donate(
    conversationIdentifier: String, name: String, imageData: Data?, completion: @escaping (Error?) -> Void
  ) {
    let interaction = INInteraction(
      intent: intent(conversationIdentifier: conversationIdentifier, name: name, imageData: imageData),
      response: nil)
    interaction.direction = .outgoing
    interaction.donate(completion: completion)
  }
}
