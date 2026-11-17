import Contracts
import CoreGraphics
import XCTest

@testable import Rendering

final class WindowOrderTests: XCTestCase {
  private let display = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
  private let other = ScreenRect(x: -1920, y: 0, width: 1920, height: 1080)
  private let focus = WindowReference(windowID: 10, ownerPID: 1, generation: 1)
  private let dialog = WindowReference(windowID: 11, ownerPID: 1, generation: 1)
  private let own: Int32 = 99

  private var order: AnchorOrder {
    AnchorOrder(RenderAnchor(window: focus, group: [focus, dialog]), ownProcessID: own)
  }

  private func window(_ id: UInt32, pid: Int32 = 2, level: Int = 0, on frame: ScreenRect? = nil)
    -> LiveWindow
  {
    LiveWindow(
      id: id, ownerPID: pid, level: level,
      frame: frame ?? ScreenRect(x: 100, y: 100, width: 400, height: 300))
  }

  func testAnchoringAllowedWhenOnlyTheGroupIsInFront() {
    let windows = [window(11, pid: 1), window(10, pid: 1), window(20)]
    XCTAssertTrue(order.allowsAnchoring(on: display, in: windows))
  }

  func testForeignWindowInFrontOfTheAnchorBlocksAnchoring() {
    let windows = [window(20), window(10, pid: 1)]
    XCTAssertFalse(order.allowsAnchoring(on: display, in: windows))
  }

  func testIrrelevantWindowsInFrontAreIgnored() {
    let windows = [
      window(30, level: 25), window(31, pid: own), window(32, on: other),
      LiveWindow(id: 33, ownerPID: 2, frame: display, alpha: 0.01), window(10, pid: 1),
    ]
    XCTAssertTrue(order.allowsAnchoring(on: display, in: windows))
    // The window on the other display does block anchoring there.
    XCTAssertFalse(order.allowsAnchoring(on: other, in: windows))
  }

  func testMissingAnchorBlocksAnchoring() {
    XCTAssertFalse(order.allowsAnchoring(on: display, in: [window(20)]))
  }

  func testSurfaceDirectlyBelowTheAnchor() {
    let windows = [window(10, pid: 1), window(500, pid: own), window(20)]
    XCTAssertTrue(order.isDirectlyBelow(surface: 500, on: display, in: windows))
  }

  func testDriftedSurfaceIsDetected() {
    let foreignBetween = [window(10, pid: 1), window(20), window(500, pid: own)]
    XCTAssertFalse(order.isDirectlyBelow(surface: 500, on: display, in: foreignBetween))
    // Foreign windows on another display do not matter for this display.
    let elsewhere = [window(10, pid: 1), window(20, on: other), window(500, pid: own)]
    XCTAssertTrue(order.isDirectlyBelow(surface: 500, on: display, in: elsewhere))
    let aboveAnchor = [window(500, pid: own), window(10, pid: 1)]
    XCTAssertFalse(order.isDirectlyBelow(surface: 500, on: display, in: aboveAnchor))
    XCTAssertFalse(order.isDirectlyBelow(surface: 500, on: display, in: [window(10, pid: 1)]))
  }

  func testParsesWindowListDictionaries() throws {
    let bounds = CGRect(x: -20, y: 30, width: 400, height: 300).dictionaryRepresentation
    let info: [String: Any] = [
      kCGWindowNumber as String: NSNumber(value: 42),
      kCGWindowOwnerPID as String: NSNumber(value: 7),
      kCGWindowLayer as String: NSNumber(value: 0), kCGWindowBounds as String: bounds,
      kCGWindowAlpha as String: NSNumber(value: 0.5),
    ]
    let parsed = try XCTUnwrap(LiveWindow(info: info))
    XCTAssertEqual(
      parsed,
      LiveWindow(
        id: 42, ownerPID: 7, level: 0, frame: ScreenRect(x: -20, y: 30, width: 400, height: 300),
        alpha: 0.5))
    var incomplete = info
    incomplete[kCGWindowBounds as String] = nil
    XCTAssertNil(LiveWindow(info: incomplete))
  }
}
