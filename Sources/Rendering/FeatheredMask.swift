import Accelerate
import CoreGraphics
import Foundation

/// Soft-edged mask image: the rectangles are drawn into a low-resolution
/// alpha bitmap, box-blurred three times (close to a Gaussian) and scaled up
/// by the render server with linear filtering. A mask layer ignores shadows,
/// so this is the public way to feather mask edges. Rectangles touching the
/// panel border are extended past it first, so the screen edges never fade.
enum FeatheredMask {
  /// Bitmap pixels per point. The blur hides the low resolution.
  static let resolution: CGFloat = 0.25

  static func image(rects: [CGRect], size: CGSize, feather: CGFloat) -> CGImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    // Whole pixels, so the margin cropped away is identical on every side.
    let pad = Int((feather * 2 * resolution).rounded(.up))
    let margin = CGFloat(pad) / resolution
    let innerWidth = Int((size.width * resolution).rounded(.up))
    let innerHeight = Int((size.height * resolution).rounded(.up))
    let width = innerWidth + 2 * pad
    let height = innerHeight + 2 * pad
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.scaleBy(x: resolution, y: resolution)
    context.translateBy(x: margin, y: margin)
    context.setFillColor(gray: 1, alpha: 1)
    for rect in rects {
      context.fill(extendedPastBorder(rect, size: size, margin: margin))
    }
    blur(context, radius: Int((feather * resolution).rounded()))
    guard let source = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    // Crop away the margin; a layer mask reads only alpha, so store the
    // coverage as premultiplied white. Row 0 of the bitmap is the top.
    var pixels = [UInt8](repeating: 0, count: innerWidth * innerHeight * 4)
    for row in 0..<innerHeight {
      let line = source + (row + pad) * width + pad
      for column in 0..<innerWidth {
        let value = line[column]
        let index = (row * innerWidth + column) * 4
        pixels[index] = value
        pixels[index + 1] = value
        pixels[index + 2] = value
        pixels[index + 3] = value
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: innerWidth, height: innerHeight, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: innerWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  static func extendedPastBorder(_ rect: CGRect, size: CGSize, margin: CGFloat) -> CGRect {
    let tolerance: CGFloat = 0.5
    var minX = rect.minX
    var minY = rect.minY
    var maxX = rect.maxX
    var maxY = rect.maxY
    if minX <= tolerance { minX -= margin }
    if minY <= tolerance { minY -= margin }
    if maxX >= size.width - tolerance { maxX += margin }
    if maxY >= size.height - tolerance { maxY += margin }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func blur(_ context: CGContext, radius: Int) {
    guard radius > 0, let data = context.data else { return }
    var buffer = vImage_Buffer(
      data: data, height: vImagePixelCount(context.height),
      width: vImagePixelCount(context.width), rowBytes: context.bytesPerRow)
    guard let scratch = malloc(context.bytesPerRow * context.height) else { return }
    defer { free(scratch) }
    var temporary = vImage_Buffer(
      data: scratch, height: buffer.height, width: buffer.width, rowBytes: buffer.rowBytes)
    let kernel = UInt32(radius * 2 + 1)
    for _ in 0..<3 {
      vImageBoxConvolve_Planar8(
        &buffer, &temporary, nil, 0, 0, kernel, kernel, 0, vImage_Flags(kvImageEdgeExtend))
      swap(&buffer, &temporary)
    }
    // Three passes leave the result in `scratch`; copy it back.
    memcpy(data, buffer.data, context.bytesPerRow * context.height)
  }
}
