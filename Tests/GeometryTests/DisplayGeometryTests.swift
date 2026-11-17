import Contracts
import TestSupport
import XCTest

@testable import Geometry

final class DisplayGeometryTests: XCTestCase {
  private let half = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)

  func testNormalizedToScreenOnPrimaryRetinaDisplay() throws {
    let primary = try XCTUnwrap(DesktopFixtures.overlappingWindows().displays.first)
    XCTAssertEqual(primary.scale, 2)
    XCTAssertEqual(
      DisplayGeometry.screenRect(for: half, on: primary),
      ScreenRect(x: 360, y: 450, width: 720, height: 225))
  }

  func testNormalizedToScreenOnDisplayWithNegativeOriginAndScaleOne() throws {
    let secondary = try XCTUnwrap(DesktopFixtures.overlappingWindows().displays.last)
    XCTAssertEqual(secondary.frame.x, -1920)
    XCTAssertEqual(
      DisplayGeometry.screenRect(for: half, on: secondary),
      ScreenRect(x: -1440, y: 440, width: 960, height: 270))
  }

  func testScaleFactorDoesNotChangePointConversion() {
    let frame = ScreenRect(x: -1280, y: -800, width: 1280, height: 800)
    let lowDPI = DisplaySnapshot(
      id: DisplayID(rawValue: "a"), runtimeID: 1, name: "A", frame: frame, scale: 1)
    let retina = DisplaySnapshot(
      id: DisplayID(rawValue: "a"), runtimeID: 1, name: "A", frame: frame, scale: 2)
    XCTAssertEqual(
      DisplayGeometry.screenRect(for: half, on: lowDPI),
      DisplayGeometry.screenRect(for: half, on: retina))
  }

  func testResolutionChangeKeepsRelativePlacement() throws {
    let before = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
    let after = ScreenRect(x: 0, y: 0, width: 1920, height: 1200)
    let global = try XCTUnwrap(DisplayGeometry.screenRect(for: half, in: before))
    let stored = try XCTUnwrap(DisplayGeometry.normalizedRect(for: global, in: before))
    XCTAssertEqual(
      DisplayGeometry.screenRect(for: stored, in: after),
      ScreenRect(x: 480, y: 600, width: 960, height: 300))
  }

  func testRoundTripOnNegativeOriginFrame() throws {
    let frame = ScreenRect(x: -1920, y: -100, width: 1920, height: 1080)
    let global = ScreenRect(x: -1800, y: 20, width: 600, height: 540)
    let normalized = try XCTUnwrap(DisplayGeometry.normalizedRect(for: global, in: frame))
    XCTAssertEqual(normalized.x, 0.0625, accuracy: 1e-12)
    XCTAssertEqual(normalized.y, 120.0 / 1080, accuracy: 1e-12)
    let back = try XCTUnwrap(DisplayGeometry.screenRect(for: normalized, in: frame))
    XCTAssertEqual(back.x, global.x, accuracy: 1e-9)
    XCTAssertEqual(back.y, global.y, accuracy: 1e-9)
    XCTAssertEqual(back.width, global.width, accuracy: 1e-9)
    XCTAssertEqual(back.height, global.height, accuracy: 1e-9)
  }

  func testNormalizedRectOfPartlyOutsideScreenRectIsClippedToDisplay() {
    let frame = ScreenRect(x: 0, y: 0, width: 1000, height: 500)
    let crossing = ScreenRect(x: 900, y: -100, width: 300, height: 200)
    XCTAssertEqual(
      DisplayGeometry.normalizedRect(for: crossing, in: frame),
      NormalizedRect(x: 0.9, y: 0, width: 0.1, height: 0.2))
    XCTAssertNil(
      DisplayGeometry.normalizedRect(
        for: ScreenRect(x: 2000, y: 0, width: 10, height: 10), in: frame))
  }

  func testValidationClipsToUnitSquare() {
    XCTAssertEqual(
      DisplayGeometry.validated(NormalizedRect(x: -0.5, y: 0.75, width: 1, height: 1)),
      NormalizedRect(x: 0, y: 0.75, width: 0.5, height: 0.25))
    XCTAssertEqual(
      DisplayGeometry.validated(NormalizedRect(x: 0, y: 0, width: 1, height: 1)),
      NormalizedRect(x: 0, y: 0, width: 1, height: 1))
  }

  func testValidationRejectsEmptyOutsideAndNonFiniteRects() {
    let invalid = [
      NormalizedRect(x: 0, y: 0, width: 0, height: 0.5),
      NormalizedRect(x: 0, y: 0, width: -0.2, height: 0.5),
      NormalizedRect(x: 1.2, y: 0, width: 0.5, height: 0.5),
      NormalizedRect(x: 0, y: -2, width: 0.5, height: 1),
      NormalizedRect(x: .nan, y: 0, width: 0.5, height: 0.5),
      NormalizedRect(x: 0, y: 0, width: .infinity, height: 0.5),
    ]
    for rect in invalid {
      XCTAssertNil(DisplayGeometry.validated(rect), "\(rect)")
      XCTAssertNil(
        DisplayGeometry.screenRect(for: rect, in: ScreenRect(x: 0, y: 0, width: 10, height: 10)))
    }
  }

  func testConversionRejectsUnusableDisplayFrame() {
    XCTAssertNil(
      DisplayGeometry.screenRect(for: half, in: ScreenRect(x: 0, y: 0, width: 0, height: 900)))
  }

  func testClippingRegionToDisplayFrame() {
    let frame = ScreenRect(x: -1920, y: -100, width: 1920, height: 1080)
    let window = ScreenRegion(ScreenRect(x: -200, y: 50, width: 1000, height: 700))
    XCTAssertEqual(
      DisplayGeometry.clipped(window, to: frame).rectangles,
      [ScreenRect(x: -200, y: 50, width: 200, height: 700)])
    XCTAssertTrue(
      DisplayGeometry.clipped(window, to: ScreenRect(x: 5000, y: 0, width: 10, height: 10)).isEmpty)
  }
}
