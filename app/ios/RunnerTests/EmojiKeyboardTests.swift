import XCTest

@testable import Runner

final class EmojiKeyboardTests: XCTestCase {
  func testFirstEmojiKeepsWholeSequences() {
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: "🎉"), "🎉")
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: "👍🏽"), "👍🏽", "with its skin tone")
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: "👨‍👩‍👧"), "👨‍👩‍👧", "a ZWJ family")
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: "🇦🇹"), "🇦🇹", "a flag")
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: "❤️"), "❤️", "text-default with a variation selector")
    XCTAssertEqual(EmojiKeyboard.firstEmoji(in: " 😀"), "😀", "after a space")
  }

  func testNoEmojiInPlainText() {
    XCTAssertNil(EmojiKeyboard.firstEmoji(in: ""))
    XCTAssertNil(EmojiKeyboard.firstEmoji(in: " "))
    XCTAssertNil(EmojiKeyboard.firstEmoji(in: "a1#"), "digits and # are emoji-capable, but not emoji")
  }

  func testTheFieldAsksForTheEmojiKeyboard() throws {
    let emoji = try XCTUnwrap(EmojiTextField.emojiInputMode, "the simulator has the emoji keyboard enabled")
    XCTAssertEqual(EmojiTextField().textInputMode, emoji)
  }
}
