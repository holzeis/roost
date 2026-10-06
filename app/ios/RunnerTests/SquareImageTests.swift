import UIKit
import XCTest

@testable import Runner

final class SquareImageTests: XCTestCase {
  /// A [width]×[height] picture: blue on the outer quarters of its long
  /// side, green in the middle.
  private func picture(width: CGFloat, height: CGFloat) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
      UIColor.blue.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
      UIColor.green.setFill()
      let side = min(width, height)
      ctx.fill(CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side))
    }
  }

  private func check(_ data: Data?, side: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
    let image = try XCTUnwrap(data.flatMap(UIImage.init(data:)), file: file, line: line)
    XCTAssertEqual(image.size.width * image.scale, side, file: file, line: line)
    XCTAssertEqual(image.size.height * image.scale, side, file: file, line: line)
    // The corner is the green middle, not the blue sides: centre-cropped,
    // not squeezed.
    let corner = try XCTUnwrap(pixel(of: image, x: 2, y: 2), file: file, line: line)
    XCTAssertGreaterThan(corner.green, 200, file: file, line: line)
    XCTAssertLessThan(corner.blue, 60, file: file, line: line)
  }

  private func pixel(of image: UIImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8)? {
    guard let cg = image.cgImage else { return nil }
    var bytes = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
    return (bytes[0], bytes[1], bytes[2])
  }

  func testLandscapeIsCroppedToItsCentre() throws {
    try check(SquareImage.crop(picture(width: 200, height: 100)), side: 100)
  }

  func testPortraitIsCroppedToItsCentre() throws {
    try check(SquareImage.crop(picture(width: 100, height: 200)), side: 100)
  }

  func testLargePicturesAreScaledDown() throws {
    try check(SquareImage.crop(picture(width: 1200, height: 800)), side: 256)
  }

  func testNotAnImage() {
    XCTAssertNil(SquareImage.crop(Data([1, 2, 3])))
  }
}
