import Contracts
import CoreGraphics
import TestSupport
import XCTest

@testable import Rendering

final class RenderGeometryTests: XCTestCase {
  private let primary = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
  private let left = ScreenRect(x: -1920, y: -100, width: 1920, height: 1080)
  private let above = ScreenRect(x: 200, y: -1080, width: 1920, height: 1080)

  func testPrimaryHeightComesFromTheDisplayAtTheQuartzOrigin() {
    let displays = DesktopFixtures.overlappingWindows().displays
    XCTAssertEqual(RenderGeometry.primaryDisplayHeight(in: displays), 900)
    XCTAssertNil(RenderGeometry.primaryDisplayHeight(in: Array(displays.dropFirst())))
  }

  func testAppKitFramesWithNegativeOrigins() {
    XCTAssertEqual(
      RenderGeometry.appKitFrame(of: primary, primaryDisplayHeight: 900),
      CGRect(x: 0, y: 0, width: 1440, height: 900))
    // Top edge 100 pt above the primary top: AppKit top = 1000, bottom = -80.
    XCTAssertEqual(
      RenderGeometry.appKitFrame(of: left, primaryDisplayHeight: 900),
      CGRect(x: -1920, y: -80, width: 1920, height: 1080))
    XCTAssertEqual(
      RenderGeometry.appKitFrame(of: above, primaryDisplayHeight: 900),
      CGRect(x: 200, y: 900, width: 1920, height: 1080))
  }

  func testLocalRectsFlipYOnTheDisplayWithNegativeOrigin() {
    let rect = ScreenRect(x: -1900, y: -50, width: 100, height: 200)
    XCTAssertEqual(
      RenderGeometry.localRects([rect], in: left), [CGRect(x: 20, y: 830, width: 100, height: 200)])
    let top = ScreenRect(x: 210, y: -1080, width: 10, height: 10)
    XCTAssertEqual(
      RenderGeometry.localRects([top], in: above), [CGRect(x: 10, y: 1070, width: 10, height: 10)])
  }

  func testLocalRectsAreClippedAndDropEmptyPieces() {
    let spanning = ScreenRect(x: -100, y: 800, width: 300, height: 200)
    XCTAssertEqual(
      RenderGeometry.localRects([spanning], in: primary),
      [CGRect(x: 0, y: 0, width: 200, height: 100)])
    XCTAssertEqual(
      RenderGeometry.localRects([spanning], in: left),
      [CGRect(x: 1820, y: 0, width: 100, height: 180)])
    XCTAssertEqual(
      RenderGeometry.localRects([ScreenRect(x: 2000, y: 0, width: 10, height: 10)], in: primary),
      [])
  }

  func testScaleDoesNotChangeMaskGeometry() {
    // The same placement in points on a 1× and a 2× display yields the same
    // local rectangles; pixel resolution only sets the layer contents scale.
    let desktop = DesktopFixtures.overlappingWindows()
    let scales = Set(desktop.displays.map(\.scale))
    XCTAssertEqual(scales, [1, 2])
    let piece = ScreenRect(x: 10, y: 20, width: 30, height: 40)
    for display in desktop.displays {
      let frame = ScreenRect(
        x: display.frame.x + 10, y: display.frame.y + 20, width: 30, height: 40)
      let local = RenderGeometry.localRects([frame], in: display.frame)
      XCTAssertEqual(local, [CGRect(x: 10, y: display.frame.height - 60, width: 30, height: 40)])
    }
    XCTAssertEqual(
      RenderGeometry.localRects([piece], in: primary),
      [CGRect(x: 10, y: 840, width: 30, height: 40)])
  }

  func testWholeDisplayNeedsNoMask() {
    XCTAssertEqual(RenderGeometry.mask(for: [primary], in: primary), .full)
    XCTAssertEqual(RenderGeometry.mask(for: [left], in: left), .full)
    XCTAssertEqual(RenderGeometry.mask(for: [], in: primary), .empty)
    XCTAssertTrue(RenderGeometry.mask(for: [], in: primary).isEmpty)
    let half = ScreenRect(x: 0, y: 0, width: 720, height: 900)
    XCTAssertEqual(
      RenderGeometry.mask(for: [half], in: primary),
      .rects([CGRect(x: 0, y: 0, width: 720, height: 900)]))
  }

  func testPathCoversTheUnionOfDisjointRects() {
    let rects = [
      CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 0, width: 10, height: 10),
    ]
    let path = RenderGeometry.path(for: rects)
    XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 30, height: 10))
    XCTAssertTrue(path.contains(CGPoint(x: 5, y: 5)))
    XCTAssertFalse(path.contains(CGPoint(x: 15, y: 5)))
    XCTAssertTrue(path.contains(CGPoint(x: 25, y: 5)))
  }
}
