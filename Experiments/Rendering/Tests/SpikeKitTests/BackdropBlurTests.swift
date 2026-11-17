import AppKit
import XCTest

@testable import SpikeKit

final class BackdropBlurTests: XCTestCase {
  @MainActor
  func testPrivateBackdropLayerAcceptsRadiusChanges() throws {
    try XCTSkipUnless(BackdropBlur.isAvailable, "CABackdropLayer/CAFilter missing on this macOS")
    let layer = try XCTUnwrap(BackdropBlur.makeLayer(radius: 12))
    XCTAssertEqual(layer.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? CGFloat, 12)
    BackdropBlur.setRadius(40, on: layer)
    XCTAssertEqual(layer.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? CGFloat, 40)
    XCTAssertEqual(layer.value(forKey: "windowServerAware") as? Bool, true)
  }

  @MainActor
  func testBackdropSharesTheEffectMaskPath() throws {
    try XCTSkipUnless(BackdropBlur.isAvailable, "CABackdropLayer/CAFilter missing on this macOS")
    let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
    let display = DisplayInfo(
      displayID: 1, name: "synthetic", uuid: "test", appKitFrame: screen, quartzBounds: screen,
      scale: 1, pixelSize: screen.size, isMain: true, menuBarInset: 0)
    let surface = MaskedEffectSurface(
      display: display, material: .hudWindow, alpha: 1, dimAlpha: 0.3)
    XCTAssertTrue(surface.useBackdrop(radius: 8))
    XCTAssertTrue(surface.effect.isHidden)
    let hole = CGPath(rect: CGRect(x: 10, y: 10, width: 50, height: 50), transform: nil)
    surface.apply(path: hole)
    let mask = try XCTUnwrap(surface.backdrop?.layer?.mask as? CAShapeLayer)
    XCTAssertEqual(mask.path, hole)
  }
}
