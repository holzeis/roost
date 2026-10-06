import Intents
import XCTest

@testable import Runner

final class ShareSuggestionDonorTests: XCTestCase {
  private let png = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

  func testCarriesTheChatsPicture() {
    let intent = ShareSuggestionDonor.intent(conversationIdentifier: "room-1", name: "Mom", imageData: png)
    XCTAssertEqual(intent.conversationIdentifier, "room-1")
    XCTAssertEqual(intent.speakableGroupName?.spokenPhrase, "Mom")
    XCTAssertNotNil(intent.image(forParameterNamed: \.speakableGroupName), "the picture travels with the donation")
  }

  func testWithoutAPictureThereIsNone() {
    let intent = ShareSuggestionDonor.intent(conversationIdentifier: "room-2", name: "Family", imageData: nil)
    XCTAssertNil(intent.image(forParameterNamed: \.speakableGroupName))
  }
}
