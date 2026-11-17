import Contracts
import XCTest

@testable import Rendering

final class CrossBlurTests: XCTestCase {
  private let target = SurfaceValues(radius: 32, dim: 0.3, blurOpacity: 0.8)

  func testBackgroundBehindBothSurfacesStaysConstant() {
    for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
      let incoming = CrossBlur.incoming(target, progress: progress)
      let outgoing = CrossBlur.outgoing(target, progress: progress)
      // Gaussian radii compose in quadrature.
      XCTAssertEqual(
        (incoming.radius * incoming.radius + outgoing.radius * outgoing.radius).squareRoot(),
        target.radius, accuracy: 1e-9)
      XCTAssertEqual((1 - incoming.dim) * (1 - outgoing.dim), 1 - target.dim, accuracy: 1e-9)
      XCTAssertEqual(
        (1 - incoming.blurOpacity) * (1 - outgoing.blurOpacity), 1 - target.blurOpacity,
        accuracy: 1e-9)
    }
  }

  func testIncomingStartsEmptyAndOutgoingEndsEmpty() {
    XCTAssertEqual(CrossBlur.incoming(target, progress: 0), .zero)
    XCTAssertEqual(CrossBlur.incoming(target, progress: 1), target)
    XCTAssertEqual(CrossBlur.outgoing(target, progress: 1), .zero)
    let start = CrossBlur.outgoing(target, progress: 0)
    XCTAssertEqual(start.radius, target.radius)
    XCTAssertEqual(start.dim, target.dim, accuracy: 1e-12)
    XCTAssertEqual(start.blurOpacity, target.blurOpacity, accuracy: 1e-12)
  }

  func testFullDimDoesNotDivideByZero() {
    let black = SurfaceValues(radius: 0, dim: 1, blurOpacity: 1)
    XCTAssertEqual(CrossBlur.outgoing(black, progress: 1).dim, 0)
    XCTAssertEqual(CrossBlur.outgoing(black, progress: 0.5).dim, 1)
  }

  func testSamplesAreEasedAndMonotonic() {
    let samples = CrossBlur.samples()
    XCTAssertEqual(samples.count, 24)
    XCTAssertEqual(samples.first, 0)
    XCTAssertEqual(samples.last, 1)
    XCTAssertEqual(samples, samples.sorted())
    XCTAssertEqual(CrossBlur.eased(0.5), 0.5)
    XCTAssertLessThan(CrossBlur.eased(0.1), 0.1)
    XCTAssertEqual(CrossBlur.eased(.nan), 1)
  }

  func testAnimationsEndAtTheirModelValues() {
    let cross = SurfaceAnimation.crossIn(to: target, duration: 0.75)
    XCTAssertEqual(cross.frames.count, 24)
    XCTAssertEqual(cross.final, target)
    XCTAssertEqual(cross.keyTimes.first, 0)
    XCTAssertEqual(cross.keyTimes.last, 1)
    XCTAssertEqual(SurfaceAnimation.crossOut(from: target, duration: 0.75).final, .zero)
    let fade = SurfaceAnimation.fade(from: .zero, to: target, duration: 0.5)
    XCTAssertEqual(fade.frames.first, .zero)
    XCTAssertEqual(fade.final, target)
  }

  func testSettingsMapping() {
    let defaults = EffectAppearance(EffectSettings())
    XCTAssertEqual(defaults.radius, 32)
    XCTAssertEqual(defaults.dim, 0.3, accuracy: 1e-12)
    XCTAssertEqual(defaults.fallbackOpacity, 1)
    XCTAssertEqual(defaults.transitionDuration, 0.75)
    let extremes = EffectAppearance(
      EffectSettings(blur: 1, backgroundBrightness: 0, transitionDuration: 1.5))
    XCTAssertEqual(extremes.radius, EffectAppearance.maximumRadius)
    XCTAssertEqual(extremes.radius, 64)
    XCTAssertEqual(extremes.dim, 1)
    let none = EffectAppearance(EffectSettings(blur: 0, backgroundBrightness: 1))
    XCTAssertEqual(none.values, .zero)
    XCTAssertEqual(EffectAppearance(EffectSettings(blur: 0.25)).fallbackOpacity, 0.5)
  }
}
