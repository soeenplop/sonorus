import AppKit
import XCTest

@testable import SpikeKit

final class FocusTransitionTests: XCTestCase {
  func testExplicitOutgoingPathsDoNotOverlapRetainedRetirement() {
    let full = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    let first = CGPath(rect: CGRect(x: 10, y: 10, width: 40, height: 40), transform: nil)
    let second = CGPath(rect: CGRect(x: 30, y: 10, width: 40, height: 40), transform: nil)
    var transition = FocusTransition(duration: 0.18)
    transition.retarget(full, at: 0, animate: false)
    transition.retarget(full, at: 0.01, animate: true, outgoing: first)
    let retainedOpacity = transition.opacity(transition.regions[0], at: 0.05)
    transition.retarget(full, at: 0.05, animate: true, outgoing: second)
    XCTAssertEqual(transition.regions.count, 2)
    let overlap = CGPoint(x: 40, y: 20)
    XCTAssertEqual(transition.regions.filter { $0.path.contains(overlap) }.count, 1)
    XCTAssertEqual(transition.regions[0].initialOpacity, retainedOpacity, accuracy: 0.001)
    XCTAssertTrue(transition.regions[1].path.contains(CGPoint(x: 60, y: 20)))
  }
  let screen = CGRect(x: 0, y: 0, width: 600, height: 400)
  func target(_ focus: CGRect) -> CGPath {
    CGPath(rect: screen, transform: nil).subtracting(CGPath(rect: focus, transform: nil))
  }
  func opacity(_ planner: FocusTransition, _ point: CGPoint, _ time: Double) -> Double {
    if planner.base.contains(point) { return 1 }
    return planner.regions.filter { $0.path.contains(point) }
      .reduce(0) { $0 + planner.opacity($1, at: time) }
  }
  func testDurationParsingFiniteClampAndMonotonicProgress() {
    for (input, expected) in [
      (-1.0, 0.0), (0, 0), (0.18, 0.18), (0.75, 0.75), (2, 1.5),
      (.nan, 0.75), (.infinity, 0.75), (-.infinity, 0.75),
    ] {
      XCTAssertEqual(FocusTransition.duration(input), expected)
    }
    XCTAssertEqual(Args(["--transition", "0.18"]).double("transition", default: 1), 0.18)
    XCTAssertEqual(FocusTransition.progress(elapsed: -1, duration: 0.18), 0)
    XCTAssertEqual(FocusTransition.progress(elapsed: 0, duration: 0), 1)
    var previous = 0.0
    for frame in 0...100 {
      let progress = FocusTransition.progress(elapsed: Double(frame) / 100, duration: 0.6)
      XCTAssertGreaterThanOrEqual(progress, previous)
      XCTAssertLessThanOrEqual(progress, 1)
      previous = progress
    }
    XCTAssertEqual(previous, 1)
  }
  func testNewFocusProtectedBackgroundStableAndOldFocusMonotonic() {
    let a = CGRect(x: 10, y: 50, width: 200, height: 200)
    let b = CGRect(x: 100, y: 100, width: 200, height: 200)
    var planner = FocusTransition(duration: 0.18)
    planner.retarget(target(a), at: 0, animate: true)
    planner.retarget(target(b), at: 1, animate: true)
    var previous = 0.0
    for frame in 0...18 {
      let time = 1 + Double(frame) / 100
      // Including overlap: new focus is sharp at the first frame, all the way.
      for point in [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 250)] {
        XCTAssertEqual(opacity(planner, point, time), 0)
      }
      XCTAssertEqual(opacity(planner, CGPoint(x: 500, y: 350), time), 1)
      let alpha = opacity(planner, CGPoint(x: 50, y: 80), time)
      XCTAssertGreaterThanOrEqual(alpha, previous)
      previous = alpha
      // No pixel is assigned to two blur sources.
      for region in planner.regions {
        XCTAssertTrue(planner.base.intersection(region.path).isEmpty)
      }
    }
    XCTAssertEqual(previous, 1, accuracy: 0.00001)
  }
  func testRapidCancellationSamplesPresentationAndLatestWins() {
    let a = CGRect(x: 10, y: 50, width: 100, height: 100)
    let b = CGRect(x: 210, y: 50, width: 100, height: 100)
    let c = CGRect(x: 410, y: 50, width: 100, height: 100)
    var planner = FocusTransition(duration: 0.18)
    planner.retarget(target(a), at: 0, animate: false)
    planner.retarget(target(b), at: 1, animate: true)
    let sampled = opacity(planner, CGPoint(x: 50, y: 80), 1.06)
    let generation = planner.generation
    planner.retarget(target(c), at: 1.06, animate: true)
    XCTAssertGreaterThan(planner.generation, generation)
    XCTAssertEqual(opacity(planner, CGPoint(x: 50, y: 80), 1.06), sampled)
    XCTAssertEqual(opacity(planner, CGPoint(x: 250, y: 80), 1.06), 0)
    for time in [1.06, 1.1, 1.24, 10] {
      XCTAssertEqual(opacity(planner, CGPoint(x: 450, y: 80), time), 0)
      XCTAssertEqual(opacity(planner, CGPoint(x: 550, y: 350), time), 1)
    }
    XCTAssertEqual(opacity(planner, CGPoint(x: 50, y: 80), 1.25), 1)
    // Slow mask preparation must not consume the transition before presentation.
    planner.begin(at: 2)
    XCTAssertEqual(opacity(planner, CGPoint(x: 50, y: 80), 2), sampled)
    XCTAssertEqual(opacity(planner, CGPoint(x: 50, y: 80), 2.18), 1)
    planner.cancel()
    XCTAssertNil(planner.target)
    XCTAssertTrue(planner.regions.isEmpty)
  }
  func testIndependentScreensInstantModeAndAllocationBound() {
    var first = FocusTransition(duration: 0.18)
    var second = FocusTransition(duration: 0.18)
    let a = target(CGRect(x: 10, y: 10, width: 20, height: 20))
    let b = target(CGRect(x: 50, y: 10, width: 20, height: 20))
    first.retarget(a, at: 0, animate: false)
    second.retarget(b, at: 0, animate: false)
    first.retarget(b, at: 1, animate: true)
    first.cancel()
    XCTAssertEqual(second.target, b)
    XCTAssertTrue(second.regions.isEmpty)
    var instant = FocusTransition(duration: 0)
    instant.retarget(a, at: 0, animate: false)
    instant.retarget(b, at: 1, animate: true)
    XCTAssertTrue(instant.regions.isEmpty)
    XCTAssertEqual(instant.base, b)
    for index in 0..<100 {
      second.retarget(
        target(CGRect(x: index * 5, y: 10, width: 4, height: 20)),
        at: Double(index) / 10000, animate: true)
      XCTAssertLessThanOrEqual(second.regions.count, FocusTransition.maximumRegions)
      second.limitRasterArea(to: 2000)
      let area = second.regions.reduce(CGFloat(0)) {
        let box = $1.path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        return $0 + box.width * box.height
      }
      XCTAssertLessThanOrEqual(area, 2000)
      for (i, region) in second.regions.enumerated() {
        for other in second.regions.dropFirst(i + 1) {
          let overlap = region.path.intersection(other.path).boundingBoxOfPath
          // CGPath boolean operations have sub-micro-point roundoff at shared
          // edges. No overlap may have a meaningful area or cover pixel centers.
          XCTAssertTrue(overlap.isNull || min(overlap.width, overlap.height) < 0.0001)
          for x in stride(from: 0.25, to: 600, by: 0.5) {
            let pixel = CGPoint(x: x, y: 15.25)
            XCTAssertFalse(region.path.contains(pixel) && other.path.contains(pixel))
          }
        }
      }
    }
  }
  @MainActor
  func testNeutralMenuPixelsAndCroppedMaskUseSameEnvelope() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let path = CGPath(rect: bounds, transform: nil)
    for scale: CGFloat in [1, 2] {
      for inset: CGFloat in [24, 33] {
        let neutral = MenuFade.insideMenuBar(bounds: bounds, menuInset: inset, points: 0)
        let bitmap =
          NativeEffectMask.image(path: path, fade: neutral, scale: scale)
          .representations.first as! NSBitmapImageRep
        // Entire menu plus content boundary: no alpha/light stripe or gap.
        for row in 0...Int((inset + 2) * scale) {
          XCTAssertEqual(bitmap.colorAt(x: 10, y: row)!.alphaComponent, 1, accuracy: 0.001)
        }
        let soft = MenuFade.insideMenuBar(bounds: bounds, menuInset: inset, points: 12)
        let crop = CGRect(x: 10, y: 60, width: 20, height: 40)
        let full =
          NativeEffectMask.image(path: path, fade: soft, scale: scale)
          .representations.first as! NSBitmapImageRep
        let local =
          NativeEffectMask.image(path: path, fade: soft, scale: scale, crop: crop)
          .representations.first as! NSBitmapImageRep
        XCTAssertEqual(local.pixelsWide, Int(20 * scale))
        for row in 0..<Int(40 * scale) {
          XCTAssertEqual(
            local.colorAt(x: 5, y: row)!.alphaComponent,
            full.colorAt(x: Int(10 * scale) + 5, y: row)!.alphaComponent, accuracy: 0.01)
        }
        XCTAssertLessThan(full.colorAt(x: 10, y: Int((inset - 6) * scale))!.alphaComponent, 0.6)
        XCTAssertGreaterThan(full.colorAt(x: 10, y: Int(inset * scale))!.alphaComponent, 0.99)
      }
    }
  }
  @MainActor
  func testHostMaskDoesNotClipRetiringTransitionFragments() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let display = DisplayInfo(
      displayID: 1, name: "synthetic", uuid: "test", appKitFrame: frame,
      quartzBounds: frame, scale: 2, pixelSize: CGSize(width: 200, height: 200),
      isMain: true, menuBarInset: 24)
    let surface = MaskedEffectSurface(
      display: display, material: .hudWindow, alpha: 1, dimAlpha: 0.3, maskOnHost: true)
    let transition = FocusTransitionSurface(
      surface: surface, duration: 0.18, material: .hudWindow, alpha: 1, dimAlpha: 0.3,
      fade: MenuFade.insideMenuBar(bounds: frame, menuInset: 24, points: 0), native: false)
    let first = CGPath(rect: frame, transform: nil).subtracting(
      CGPath(rect: CGRect(x: 0, y: 0, width: 30, height: 30), transform: nil))
    let second = CGPath(rect: frame, transform: nil).subtracting(
      CGPath(rect: CGRect(x: 60, y: 60, width: 30, height: 30), transform: nil))
    transition.retarget(first, animate: false)
    transition.retarget(second, animate: true)
    XCTAssertNil(surface.host.layer?.mask)
    XCTAssertTrue(surface.effect.layer?.mask === surface.effectMask)
    XCTAssertFalse(transition.planner.regions.isEmpty)
    XCTAssertGreaterThan(surface.host.subviews.count, 2)
    transition.cancel(reason: "test")
    XCTAssertEqual(surface.host.subviews.count, 2)
  }

}
