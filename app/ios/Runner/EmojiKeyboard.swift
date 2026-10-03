import Flutter
import UIKit

/// Opens iOS's own emoji keyboard to pick one emoji, for reacting to a
/// message with one that isn't in the quick list (see the Dart side,
/// lib/features/chat/system_emoji_keyboard.dart). Flutter's text input can
/// only show the ordinary keyboard, so this uses a hidden native text field
/// that asks for the emoji keyboard instead. The first emoji typed is the
/// result; Cancel in the bar above the keyboard picks nothing.
///
/// Channel "roost/emoji_keyboard":
///   "isAvailable" → Bool: the user has the emoji keyboard enabled
///   "pick"        → String? (the emoji, or nil when cancelled)
///   "cancel"      → closes an open keyboard, picking nothing
final class EmojiKeyboard: NSObject {
  static let shared = EmojiKeyboard()

  private var field: EmojiTextField?
  private var pending: FlutterResult?

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(name: "roost/emoji_keyboard", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, result in
        guard let self else { return result(nil) }
        switch call.method {
        case "isAvailable": result(EmojiTextField.emojiInputMode != nil)
        case "pick": self.pick(result)
        case "cancel":
          self.finish(with: nil)
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard EmojiTextField.emojiInputMode != nil else {
      return result(FlutterError(code: "unavailable", message: "The emoji keyboard isn't enabled", details: nil))
    }
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else {
      return result(FlutterError(code: "no_window", message: nil, details: nil))
    }
    finish(with: nil)  // Only one pick at a time.
    pending = result

    let field = EmojiTextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
    field.alpha = 0.01
    field.autocorrectionType = .no
    field.inputAccessoryView = cancelBar()
    field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
    window.addSubview(field)
    self.field = field
    field.becomeFirstResponder()
  }

  @objc private func textChanged(_ field: UITextField) {
    guard let emoji = Self.firstEmoji(in: field.text ?? "") else {
      field.text = ""  // A space or anything else: keep waiting for an emoji.
      return
    }
    finish(with: emoji)
  }

  @objc private func cancelTapped() {
    finish(with: nil)
  }

  private func finish(with emoji: String?) {
    field?.resignFirstResponder()
    field?.removeFromSuperview()
    field = nil
    let result = pending
    pending = nil
    result?(emoji)
  }

  private func cancelBar() -> UIView {
    let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    let title = UIBarButtonItem(title: "Choose a reaction", style: .plain, target: nil, action: nil)
    title.isEnabled = false
    bar.items = [
      title,
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)),
    ]
    bar.sizeToFit()
    return bar
  }

  /// The first emoji in [text], whole (with its skin tone, flag pair or
  /// ZWJ sequence), or nil if it has none.
  static func firstEmoji(in text: String) -> String? {
    text.first(where: isEmoji).map(String.init)
  }

  static func isEmoji(_ character: Character) -> Bool {
    guard let first = character.unicodeScalars.first else { return false }
    // Emoji that render as emoji by default, or that become one with a
    // variation selector / modifier / ZWJ (e.g. "❤️", "👍🏽"); not plain
    // digits or "#", which are technically emoji-capable too.
    return first.properties.isEmojiPresentation
      || (first.properties.isEmoji && character.unicodeScalars.count > 1)
  }
}

/// A text field that brings up the emoji keyboard rather than the user's
/// usual one: UIKit shows whatever input mode a responder reports.
final class EmojiTextField: UITextField {
  static var emojiInputMode: UITextInputMode? {
    UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
  }

  override var textInputMode: UITextInputMode? {
    Self.emojiInputMode ?? super.textInputMode
  }
}
