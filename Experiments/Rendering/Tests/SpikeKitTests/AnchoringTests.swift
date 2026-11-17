import CoreGraphics
import XCTest

@testable import SpikeKit

final class AnchoringTests: XCTestCase {
  func window(
    _ id: UInt32, _ pid: Int32, _ rect: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
    layer: Int = 0
  ) -> CGWin {
    CGWin(id: id, pid: pid, owner: "test", layer: layer, bounds: rect)
  }

  func testGroupAndForeignFallback() {
    let sheet = window(1, 1, CGRect(x: 10, y: 10, width: 20, height: 20))
    let parent = window(2, 1)
    let other = window(3, 2)
    let plan = Anchoring.plan(frontToBack: [sheet, parent, other], focused: parent)
    XCTAssertEqual(plan.anchor?.id, 2)
    XCTAssertEqual(plan.group.map(\.id), [1, 2])
    XCTAssertEqual(plan.behind.map(\.id), [3])
    XCTAssertNil(Anchoring.plan(frontToBack: [other, sheet, parent], focused: parent).anchor)
  }

  func testVerificationAndFallbackMask() {
    let focus = window(1, 1)
    let other = window(2, 2)
    let panel = window(9, 9)
    let plan = Anchoring.plan(frontToBack: [focus, other], focused: focus)
    XCTAssertTrue(
      Anchoring.isPlacementCorrect(frontToBack: [focus, panel, other], ownIDs: [9], plan: plan))
    XCTAssertFalse(
      Anchoring.isPlacementCorrect(frontToBack: [focus, other, panel], ownIDs: [9], plan: plan))
    let fallback = Anchoring.fallback(plan, reason: "test")
    XCTAssertEqual(Anchoring.scopeHoles(for: fallback, exceptions: []).last?.kind, .punch)
    XCTAssertTrue(Anchoring.scopeHoles(for: plan, exceptions: []).isEmpty)
  }

  func testNegativeDisplayCoordinates() {
    let screen = CGRect(x: -1000, y: 0, width: 1000, height: 800)
    let rect = CGRect(x: -900, y: 50, width: 100, height: 200)
    XCTAssertEqual(
      MaskPath.local(rect, screen: screen, flipped: false),
      CGRect(x: 100, y: 550, width: 100, height: 200))
  }

  func testEveryPanelMustBeBehindTheEntireGroup() {
    let focus = window(1, 1)
    let sheet = window(2, 1)
    let inactive = window(3, 3)
    let first = window(8, 8)
    let second = window(9, 8)
    let plan = Anchoring.plan(frontToBack: [sheet, focus, inactive], focused: focus)
    for invalid in [
      [first, sheet, focus, second, inactive],
      [sheet, first, focus, second, inactive],
      [sheet, focus, first, inactive, second],
    ] {
      XCTAssertFalse(
        Anchoring.isPlacementCorrect(frontToBack: invalid, ownIDs: [8, 9], plan: plan))
    }
    XCTAssertTrue(
      Anchoring.isPlacementCorrect(
        frontToBack: [sheet, focus, first, second, inactive], ownIDs: [8, 9], plan: plan))
  }

  func testForeignUnavailableFocusClearsOldTargetAndCanRecover() {
    let old = window(1, 1)
    XCTAssertNil(FocusContinuity.target(resolved: nil, previous: old, ownUIIsActive: false))
    XCTAssertEqual(FocusContinuity.target(resolved: nil, previous: old, ownUIIsActive: true), old)
    let new = window(2, 2)
    XCTAssertEqual(FocusContinuity.target(resolved: new, previous: nil, ownUIIsActive: false), new)
  }

  func testFailedAnchorStaysInFallbackUntilChangedOrReset() {
    let focus = window(1, 1)
    let plan = Anchoring.plan(frontToBack: [focus], focused: focus)
    var cache = AnchorFailureCache()
    cache.record(plan)
    XCTAssertNil(cache.applying(to: plan).anchor)
    XCTAssertNil(cache.applying(to: plan).anchor)
    cache.reset()
    XCTAssertEqual(cache.applying(to: plan).anchor?.id, 1)
    cache.record(plan)
    let next = window(2, 2)
    XCTAssertEqual(
      cache.applying(to: Anchoring.plan(frontToBack: [next], focused: next)).anchor?.id, 2)
  }

  func testFullScopeDoesNotExemptUnselectedNegativeLevelSurfaces() {
    let focus = window(1, 1, CGRect(x: 0, y: 0, width: 10, height: 10))
    let foreground = window(2, 2, CGRect(x: 20, y: 20, width: 20, height: 20))
    let system = window(3, 3, CGRect(x: 20, y: 20, width: 40, height: 40), layer: -1)
    let plan = Anchoring.fallback(
      Anchoring.plan(frontToBack: [focus, foreground, system], focused: focus), reason: "test")
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    let path = MaskPath.painter(
      pieces: [MaskPiece(rect: screen, kind: .effect)]
        + Anchoring.scopeHoles(for: plan, exceptions: []),
      screen: screen, cornerRadius: 0, flipped: true)
    XCTAssertTrue(path.contains(CGPoint(x: 25, y: 25)))
    XCTAssertTrue(path.contains(CGPoint(x: 55, y: 55)))
    XCTAssertTrue(path.contains(CGPoint(x: 90, y: 90)))
  }

  func testAlphaThresholdChangesMaskEligibilityWithoutGeometryChange() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    func eligible(_ alpha: Double) -> [CGWin] {
      [CGWin(id: 1, pid: 1, owner: "test", bounds: rect, alpha: alpha)].filter(\.isMaskEligible)
    }
    XCTAssertTrue(eligible(0).isEmpty)
    XCTAssertTrue(eligible(0.05).isEmpty)
    XCTAssertEqual(eligible(0.06).count, 1)
    XCTAssertTrue(eligible(.nan).isEmpty)
  }

  func testContainingSameAppWindowBehindFocusIsNotAssumedToBeAParent() {
    let focus = window(1, 1, CGRect(x: 20, y: 100, width: 40, height: 40))
    let otherDocument = window(2, 1, CGRect(x: 0, y: 0, width: 100, height: 200))
    let plan = Anchoring.plan(frontToBack: [focus, otherDocument], focused: focus)
    XCTAssertEqual(plan.anchor?.id, focus.id)
    XCTAssertEqual(plan.groupIDs, [focus.id])
    XCTAssertEqual(plan.behind.map(\.id), [otherDocument.id])
  }

  func testMenuWindowAbovePanelsDoesNotPunchItsWholeBoundsIntoContent() {
    let focus = window(1, 1, CGRect(x: 20, y: 100, width: 40, height: 40))
    let menuSurface = window(2, 2, CGRect(x: 0, y: 0, width: 100, height: 80), layer: 24)
    let plan = Anchoring.plan(frontToBack: [menuSurface, focus], focused: focus)
    XCTAssertTrue(Anchoring.scopeHoles(for: plan, exceptions: []).isEmpty)
    let fallback = Anchoring.fallback(plan, reason: "test")
    XCTAssertFalse(
      Anchoring.scopeHoles(for: fallback, exceptions: []).contains {
        $0.kind == .punch && $0.rect == menuSurface.bounds
      })
  }

  func testRemoteWindowChangesDoNotChangeLocalFullMask() {
    let focus = window(1, 1, CGRect(x: -100, y: 0, width: 50, height: 50))
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    for y: CGFloat in [0, 10, 40] {
      let remote = window(2, 2, CGRect(x: -100, y: y, width: 50, height: 50), layer: -1)
      let plan = Anchoring.fallback(
        Anchoring.plan(frontToBack: [focus, remote], focused: focus), reason: "remote")
      XCTAssertTrue(Anchoring.scopeHoles(for: plan, exceptions: [], clipTo: screen).isEmpty)
    }
  }

  func testFullScopeHasNoStaircaseHolesFromUnselectedHelperWindows() {
    let left = CGRect(x: -1470, y: 0, width: 1470, height: 956)
    let right = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    let focus = window(1, 1, CGRect(x: -1200, y: 200, width: 800, height: 500))
    let helpers = (0..<8).map { index in
      window(
        UInt32(10 + index), 2,
        CGRect(x: index * 400, y: 0, width: 450, height: 40 + index * 12),
        layer: index.isMultiple(of: 2) ? -1 : 1)
    }
    let inactive = window(2, 3, CGRect(x: 30, y: 20, width: 1500, height: 1200))
    let global = Anchoring.plan(frontToBack: [focus, inactive] + helpers, focused: focus)
    let remote = DisplayPlacement.plan(global, screen: right)
    let remoteHoles = Anchoring.scopeHoles(for: remote, exceptions: [], clipTo: right)
    XCTAssertTrue(remoteHoles.isEmpty)
    let localHoles = Anchoring.scopeHoles(for: global, exceptions: [], clipTo: left)
    XCTAssertTrue(localHoles.isEmpty)  // Active window is physically above local panel.
    let fallback = Anchoring.fallback(global, reason: "test")
    let fallbackHoles = Anchoring.scopeHoles(for: fallback, exceptions: [], clipTo: left)
    XCTAssertEqual(fallbackHoles.count, 1)
    XCTAssertEqual(fallbackHoles.first?.rect, focus.bounds)
  }
}
