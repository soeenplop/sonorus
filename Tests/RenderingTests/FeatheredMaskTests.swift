import CoreGraphics
import XCTest

@testable import Rendering

final class FeatheredMaskTests: XCTestCase {
  private let size = CGSize(width: 400, height: 200)

  /// Alpha at a point in panel coordinates (y up), sampled from the image.
  private func alpha(_ image: CGImage, at point: CGPoint) -> UInt8 {
    let data = image.dataProvider!.data! as Data
    let column = min(image.width - 1, Int(point.x * FeatheredMask.resolution))
    let row = min(image.height - 1, Int((size.height - point.y) * FeatheredMask.resolution))
    return data[row * image.bytesPerRow + column * 4 + 3]
  }

  func testImageIsLowResolution() throws {
    let image = try XCTUnwrap(
      FeatheredMask.image(rects: [CGRect(origin: .zero, size: size)], size: size, feather: 10))
    XCTAssertEqual(image.alphaInfo, .premultipliedLast)
    XCTAssertEqual(image.width, 100)
    XCTAssertEqual(image.height, 50)
  }

  func testHoleEdgesFadeWhilePanelBordersStayFull() throws {
    // Effect everywhere except a hole on the right half's centre.
    let rects = [
      CGRect(x: 0, y: 0, width: 200, height: 200),
      CGRect(x: 200, y: 0, width: 200, height: 60),
      CGRect(x: 200, y: 140, width: 200, height: 60),
      CGRect(x: 340, y: 60, width: 60, height: 80),
    ]
    let image = try XCTUnwrap(FeatheredMask.image(rects: rects, size: size, feather: 10))
    XCTAssertEqual(alpha(image, at: CGPoint(x: 1, y: 1)), 255, "panel corner not faded")
    XCTAssertEqual(alpha(image, at: CGPoint(x: 100, y: 100)), 255)
    XCTAssertLessThan(alpha(image, at: CGPoint(x: 270, y: 100)), 20, "hole centre clear")
    let edge = alpha(image, at: CGPoint(x: 200, y: 100))
    XCTAssertGreaterThan(edge, 40, "soft edge")
    XCTAssertLessThan(edge, 215, "soft edge")
  }

  func testRectsTouchingTheBorderExtendPastIt() {
    let extended = FeatheredMask.extendedPastBorder(
      CGRect(x: 0, y: 50, width: 400, height: 50), size: size, margin: 20)
    XCTAssertEqual(extended, CGRect(x: -20, y: 50, width: 440, height: 50))
  }
}
