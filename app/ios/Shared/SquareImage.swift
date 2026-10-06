import UIKit

/// Profile pictures keep the shape they were taken in (the server's preview
/// only scales them down), but iOS draws a person's picture in a circle and
/// stretches whatever it's given to fill it. Compiled into the app (share
/// sheet suggestions, ShareSuggestionDonor) and the notification service
/// extension (SenderAvatar), which both hand iOS such pictures.
enum SquareImage {
  /// [data] cropped to its centre square and scaled down to at most
  /// [maxSide] pixels, as JPEG; nil if it isn't an image.
  static func crop(_ data: Data, maxSide: CGFloat = 256) -> Data? {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
    // In points with the image's orientation applied, like draw(in:).
    let width = image.size.width * image.scale
    let height = image.size.height * image.scale
    let side = min(width, height)
    let output = min(side, maxSide)
    let scale = output / side

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format)
    return renderer.jpegData(withCompressionQuality: 0.9) { _ in
      image.draw(in: CGRect(
        x: -(width - side) / 2 * scale,
        y: -(height - side) / 2 * scale,
        width: width * scale,
        height: height * scale))
    }
  }
}
