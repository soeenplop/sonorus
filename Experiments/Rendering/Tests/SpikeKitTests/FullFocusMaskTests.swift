import AppKit
import XCTest

@testable import SpikeKit

final class FullFocusMaskTests: XCTestCase {
  let screen = CGRect(x: 0, y: 0, width: 600, height: 400)
  func window(_ id: UInt32, _ rect: CGRect) -> CGWin {
    CGWin(id: id, pid: Int32(id), owner: "synthetic", layer: 0, bounds: rect)
  }
  func plan(_ focus: CGWin, _ behind: [CGWin] = []) -> AnchorPlan {
    Anchoring.plan(frontToBack: [focus] + behind, focused: focus)
  }
  func path(_ plan: AnchorPlan, exceptions: Set<CGWindowID> = [], guardPlacement: Bool = false)
    -> CGPath
  {
    FullFocusMask.path(
      for: plan, exceptions: exceptions, screen: screen,
      cornerRadius: 12, guardPlacement: guardPlacement)
  }
  func testAnchoredDraggingHasStableFullCoverageAndNoRetirement() {
    var previous = plan(window(1, CGRect(x: 20, y: 40, width: 200, height: 200)))
    let full = path(previous)
    var transition = FocusTransition(duration: 0.18)
    transition.retarget(full, at: 0, animate: false)
    for index in 1...20 {
      let next = plan(window(1, CGRect(x: 20 + index * 10, y: 40, width: 200, height: 200)))
      XCTAssertEqual(path(next), full)
      XCTAssertNil(
        FullFocusMask.outgoing(
          from: previous, to: next, exceptions: [],
          screen: screen, cornerRadius: 12))
      transition.retarget(path(next), at: Double(index), animate: false)
      XCTAssertTrue(transition.regions.isEmpty)
      previous = next
    }
    XCTAssertTrue(full.contains(CGPoint(x: 21, y: 359)))
    XCTAssertEqual(full.boundingBoxOfPath, screen)
  }
  func testTrueSwitchAndRapidSwitchRetireOnlyOutgoingVisibleRegion() {
    let a = plan(window(1, CGRect(x: 20, y: 40, width: 100, height: 100)))
    let b = plan(window(2, CGRect(x: 220, y: 40, width: 100, height: 100)))
    let c = plan(window(3, CGRect(x: 420, y: 40, width: 100, height: 100)))
    var transition = FocusTransition(duration: 0.18)
    transition.retarget(path(a), at: 0, animate: false)
    for (old, new, time) in [(a, b, 1.0), (b, c, 1.05), (c, a, 1.08)] {
      let outgoing = FullFocusMask.outgoing(
        from: old, to: new, exceptions: [],
        screen: screen, cornerRadius: 12)!
      XCTAssertFalse(outgoing.contains(CGPoint(x: new.focused.bounds.midX, y: 300)))
      transition.retarget(
        path(new), at: time, animate: true, outgoing: outgoing,
        retirementClip: path(new, guardPlacement: true))
      for region in transition.regions {
        XCTAssertFalse(region.path.contains(CGPoint(x: new.focused.bounds.midX, y: 300)))
      }
      XCTAssertFalse(transition.regions.isEmpty)
    }
    XCTAssertFalse(transition.regions.contains { $0.path.contains(CGPoint(x: 50, y: 300)) })
    XCTAssertTrue(transition.regions.contains { $0.path.contains(CGPoint(x: 250, y: 300)) })
    transition.finish()
    XCTAssertTrue(transition.regions.isEmpty)
    XCTAssertEqual(transition.base, path(a))
  }
  func testReorderGuardKeepsOutgoingAndIncomingFocusSharpUntilFadeStarts() {
    let old = window(1, CGRect(x: 20, y: 40, width: 100, height: 100))
    let new = window(2, CGRect(x: 220, y: 40, width: 100, height: 100))
    let before = plan(old, [new])
    let after = plan(new, [old])
    let oldCenter = CGPoint(x: 70, y: 300)
    let newCenter = CGPoint(x: 270, y: 300)
    let background = CGPoint(x: 500, y: 100)
    let guarded = FullFocusMask.reorderGuard(
      from: before, to: after, exceptions: [], screen: screen, cornerRadius: 12)
    XCTAssertFalse(guarded.contains(oldCenter))
    XCTAssertFalse(guarded.contains(newCenter))
    XCTAssertTrue(guarded.contains(background))

    // The fade that follows starts from the same sharp outgoing area.
    var transition = FocusTransition(duration: 0.18)
    transition.retarget(path(before), at: 0, animate: false)
    transition.retarget(
      path(after), at: 1, animate: true,
      outgoing: FullFocusMask.outgoing(
        from: before, to: after, exceptions: [], screen: screen, cornerRadius: 12),
      retirementClip: path(after, guardPlacement: true))
    XCTAssertFalse(transition.base.contains(oldCenter))
    XCTAssertTrue(transition.regions.contains { $0.path.contains(oldCenter) })
    XCTAssertEqual(transition.regions.first?.initialOpacity, 0)

    // Without a focus switch the guard is the plain fallback mask.
    XCTAssertEqual(
      FullFocusMask.reorderGuard(
        from: after, to: after, exceptions: [], screen: screen, cornerRadius: 12),
      path(after, guardPlacement: true))
  }
  @MainActor
  func testOverlayRoundedPixelsAndAnchoredCornersAtBothScales() {
    let focus = window(1, CGRect(x: 20, y: 40, width: 200, height: 200))
    let anchored = plan(focus)
    let overlay = Anchoring.fallback(anchored, reason: "synthetic stale anchor")
    for scale: CGFloat in [1, 2] {
      for (mask, centerAlpha) in [(path(anchored), CGFloat(1)), (path(overlay), CGFloat(0))] {
        let fade = MenuFade(bounds: screen, menuInset: 0, points: 0)
        let bitmap =
          NativeEffectMask.image(path: mask, fade: fade, scale: scale)
          .representations.first as! NSBitmapImageRep
        XCTAssertEqual(
          bitmap.colorAt(x: Int(21 * scale), y: Int(41 * scale))!.alphaComponent,
          1, accuracy: 0.01)
        XCTAssertEqual(
          bitmap.colorAt(x: Int(100 * scale), y: Int(100 * scale))!.alphaComponent,
          centerAlpha, accuracy: 0.01)
      }
    }
  }
  func testSpanningWindowRoundedBeforeDisplayClipping() {
    let focus = window(1, CGRect(x: -100, y: 40, width: 300, height: 200))
    let mask = path(plan(focus), guardPlacement: true)
    // Display edge cuts through the straight top edge, not a new rounded corner.
    XCTAssertFalse(mask.contains(CGPoint(x: 1, y: 359)))
    XCTAssertTrue(mask.contains(CGPoint(x: 199, y: 359)))
    XCTAssertTrue(mask.contains(CGPoint(x: 1, y: 370)))
  }
  func testExceptionsBelowAnchorOccludedByRectangularRefill() {
    let focus = window(1, CGRect(x: 400, y: 40, width: 100, height: 100))
    let exception = window(2, CGRect(x: 20, y: 40, width: 200, height: 200))
    let occluder = window(3, CGRect(x: 100, y: 100, width: 100, height: 100))
    let mask = path(plan(focus, [occluder, exception]), exceptions: [2])
    XCTAssertFalse(mask.contains(CGPoint(x: 50, y: 300)))
    XCTAssertTrue(mask.contains(CGPoint(x: 101, y: 299)))
    XCTAssertTrue(mask.contains(CGPoint(x: 21, y: 359)))
    XCTAssertTrue(mask.contains(CGPoint(x: 450, y: 300)))
  }
  func testReorderGuardRestoresHistoryEvenWhenTargetUnchanged() {
    let a = plan(window(1, CGRect(x: 20, y: 40, width: 100, height: 100)))
    let b = plan(window(2, CGRect(x: 220, y: 40, width: 100, height: 100)))
    XCTAssertFalse(path(b, guardPlacement: true).contains(CGPoint(x: 250, y: 300)))
    XCTAssertTrue(path(b).contains(CGPoint(x: 250, y: 300)))
    XCTAssertNotNil(
      FullFocusMask.outgoing(
        from: a, to: b, exceptions: [],
        screen: screen, cornerRadius: 12))
  }
  func testMissingAnchorImmediatelyUsesIndependentRoundedFallback() {
    let focus = window(1, CGRect(x: 20, y: 40, width: 200, height: 200))
    let anchored = plan(focus)
    XCTAssertFalse(
      DisplayPlacement.verify(
        frontToBack: [window(9, screen)], panelID: 9,
        ownIDs: [9], expected: screen, displayID: 1, actualDisplayID: 1, plan: anchored))
    var local = AnchorFailureCache()
    let remote = AnchorFailureCache()
    local.record(anchored)
    let fallback = local.applying(to: anchored)
    XCTAssertNil(fallback.anchor)
    XCTAssertFalse(path(fallback).contains(CGPoint(x: 100, y: 300)))
    XCTAssertTrue(path(fallback).contains(CGPoint(x: 21, y: 359)))
    XCTAssertTrue(path(anchored).contains(CGPoint(x: 100, y: 300)))
    var other = remote
    XCTAssertNotNil(other.applying(to: anchored).anchor)
  }
  @MainActor
  func testGuardRetirementAndMotionCancelStaleFragmentsForBothBackends() {
    let a = plan(window(1, CGRect(x: 20, y: 40, width: 100, height: 100)))
    let b = plan(window(2, CGRect(x: 220, y: 40, width: 100, height: 100)))
    let display = DisplayInfo(
      displayID: 1, name: "synthetic", uuid: "test",
      appKitFrame: screen, quartzBounds: screen, scale: 2,
      pixelSize: CGSize(width: 1200, height: 800), isMain: true, menuBarInset: 24)
    for native in [false, true] {
      let surface = MaskedEffectSurface(
        display: display, material: .hudWindow,
        alpha: 1, dimAlpha: 0.3, maskOnHost: true)
      let transition = FocusTransitionSurface(
        surface: surface, duration: 0.18,
        material: .hudWindow, alpha: 1, dimAlpha: 0.3,
        fade: MenuFade.insideMenuBar(bounds: screen, menuInset: 24, points: 0), native: native)
      transition.retarget(path(a), animate: false)
      transition.guardPlacement(path(b, guardPlacement: true))
      XCTAssertEqual(transition.planner.target, path(a))
      transition.retarget(
        path(b), animate: true,
        outgoing: FullFocusMask.outgoing(
          from: a, to: b, exceptions: [],
          screen: screen, cornerRadius: 12))
      XCTAssertFalse(transition.planner.regions.isEmpty)
      let generation = transition.planner.generation
      // The retiring fragment over `a` lies outside b's protection and keeps
      // its sampled opacity; a guard protecting `a` must hide it.
      transition.guardPlacement(path(b, guardPlacement: true))
      XCTAssertTrue(surface.host.subviews.dropFirst(2).allSatisfy { !$0.isHidden })
      transition.guardPlacement(path(a, guardPlacement: true))
      XCTAssertTrue(surface.host.subviews.dropFirst(2).allSatisfy { $0.isHidden })
      transition.retarget(path(b), animate: false)
      XCTAssertEqual(transition.planner.generation, generation)
      XCTAssertTrue(surface.host.subviews.dropFirst(2).allSatisfy { !$0.isHidden })
      XCTAssertNil(surface.host.layer?.mask)
      // A failed anchor or overlay motion replaces all old retirement holes now.
      transition.retarget(path(b, guardPlacement: true), animate: false)
      XCTAssertTrue(transition.planner.regions.isEmpty)
      XCTAssertEqual(surface.host.subviews.count, 2)
      transition.cancel(reason: "test")
    }
  }

}
