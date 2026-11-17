import AppKit
import XCTest

@testable import Rendering

/// Headless: views and layers only, no window is created or shown.
@MainActor
final class EffectContentViewTests: XCTestCase {
  private let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
  private let values = SurfaceValues(radius: 24, dim: 0.3, blurOpacity: 0.8)

  private func backdropView() throws -> EffectContentView {
    let layer = try XCTUnwrap(
      BackdropBlur.makeLayer(), "CABackdropLayer/CAFilter missing on this macOS")
    return EffectContentView(frame: frame, blur: .backdrop(layer))
  }

  private func radius(of view: EffectContentView) -> Double? {
    (view.blurLayer?.value(forKeyPath: BackdropBlur.radiusKeyPath) as? NSNumber)?.doubleValue
  }

  func testBackdropLayerIsConfiguredForWindowServerBlur() throws {
    try XCTSkipIf(BackdropBlur.makeLayer() == nil, "private backdrop blur unavailable")
    let layer = try XCTUnwrap(BackdropBlur.makeLayer())
    XCTAssertEqual(layer.value(forKey: "windowServerAware") as? Bool, true)
    XCTAssertEqual((layer.value(forKey: "scale") as? NSNumber)?.doubleValue, 1)
    XCTAssertEqual((layer.value(forKeyPath: BackdropBlur.radiusKeyPath) as? NSNumber), 0)
    BackdropBlur.setRadius(40, on: layer)
    XCTAssertEqual((layer.value(forKeyPath: BackdropBlur.radiusKeyPath) as? NSNumber), 40)
    BackdropBlur.setRadius(-5, on: layer)
    XCTAssertEqual((layer.value(forKeyPath: BackdropBlur.radiusKeyPath) as? NSNumber), 0)
  }

  func testMasksBothBlurAndDimWithTheSameFeatheredImage() throws {
    try XCTSkipIf(BackdropBlur.makeLayer() == nil, "private backdrop blur unavailable")
    let view = try backdropView()
    let rects = [CGRect(x: 10, y: 10, width: 50, height: 50)]
    view.setMask(.rects(rects))
    let blurMask = try XCTUnwrap(view.blurLayer?.mask)
    let dimMask = try XCTUnwrap(view.dimLayer.mask)
    XCTAssertNotNil(blurMask.contents)
    XCTAssertTrue((blurMask.contents as AnyObject) === (dimMask.contents as AnyObject))
    XCTAssertEqual(blurMask.contentsGravity, .resize)
    XCTAssertEqual(blurMask.frame, frame)

    view.setMask(.full)
    XCTAssertNil(view.blurLayer?.mask)
    XCTAssertNil(view.dimLayer.mask)
  }

  func testValuesAndKeyframesDriveRadiusAndDim() throws {
    try XCTSkipIf(BackdropBlur.makeLayer() == nil, "private backdrop blur unavailable")
    let view = try backdropView()
    view.setValues(values)
    XCTAssertEqual(radius(of: view), 24)
    XCTAssertEqual(view.dimLayer.opacity, 0.3)

    view.animate(.crossIn(to: SurfaceValues(radius: 48, dim: 0.5, blurOpacity: 1), duration: 0.75))
    XCTAssertEqual(radius(of: view), 48)
    XCTAssertEqual(view.dimLayer.opacity, 0.5)
    let blur = try XCTUnwrap(
      view.blurLayer?.animation(forKey: EffectContentView.blurAnimationKey) as? CAKeyframeAnimation)
    XCTAssertEqual(blur.keyPath, BackdropBlur.radiusKeyPath)
    XCTAssertEqual(blur.values?.count, 24)
    XCTAssertEqual(blur.duration, 0.75)
    let dim = try XCTUnwrap(
      view.dimLayer.animation(forKey: EffectContentView.dimAnimationKey) as? CAKeyframeAnimation)
    XCTAssertEqual(dim.keyPath, "opacity")
    XCTAssertEqual(dim.keyTimes?.last, 1)

    view.setValues(.zero)
    XCTAssertNil(view.blurLayer?.animation(forKey: EffectContentView.blurAnimationKey))
    XCTAssertNil(view.dimLayer.animation(forKey: EffectContentView.dimAnimationKey))
    XCTAssertEqual(radius(of: view), 0)
  }

  func testFallbackMaterialFadesItsOpacity() throws {
    let material = EffectContentView.makeMaterialView()
    XCTAssertEqual(material.blendingMode, .behindWindow)
    XCTAssertEqual(material.material, .hudWindow)
    XCTAssertEqual(material.state, .active)
    let view = EffectContentView(frame: frame, blur: .material(material))
    view.setValues(values)
    XCTAssertEqual(material.alphaValue, 0.8, accuracy: 1e-6)
    XCTAssertEqual(view.dimLayer.opacity, 0.3)

    view.setMask(.rects([CGRect(x: 0, y: 0, width: 20, height: 20)]))
    XCTAssertNotNil(material.layer?.mask?.contents)
    XCTAssertNotNil(view.dimLayer.mask?.contents)

    view.animate(.fade(from: values, to: .zero, duration: 0.5))
    XCTAssertEqual(material.alphaValue, 0, accuracy: 1e-6)
    let blur = try XCTUnwrap(
      material.layer?.animation(forKey: EffectContentView.blurAnimationKey)
        as? CAKeyframeAnimation)
    XCTAssertEqual(blur.keyPath, "opacity")
    XCTAssertEqual((blur.values?.first as? NSNumber)?.doubleValue ?? 0, 0.8, accuracy: 1e-9)
  }
}
