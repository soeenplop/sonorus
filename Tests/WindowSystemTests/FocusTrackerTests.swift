import Contracts
import XCTest

@testable import WindowSystem

final class FocusTrackerTests: XCTestCase {
  private let ownPID: Int32 = 999

  private func window(
    _ id: UInt32, pid: Int32, frame: ScreenRect, layer: Int = 0,
    system: Bool = false
  ) -> CatalogWindow {
    let reference = WindowReference(windowID: id, ownerPID: pid, generation: UInt64(id) * 10)
    return CatalogWindow(
      snapshot: WindowSnapshot(
        reference: reference, frame: frame, level: layer, isSystemUI: system),
      record: WindowRecord(
        windowID: id, ownerPID: pid, layer: layer, frame: frame))
  }

  func testFrontmostNormalWindowIsUncertain() {
    var tracker = FocusTracker(ownPID: ownPID)
    let windows = [
      window(1, pid: 20, frame: rect(0, 0, 500, 400)),
      window(2, pid: 10, frame: rect(0, 0, 100, 100), layer: 3),
      window(3, pid: 10, frame: rect(0, 0, 500, 400)),
      window(4, pid: 10, frame: rect(50, 50, 500, 400)),
    ]
    let state = tracker.resolve(frontmostPID: 10, windows: windows)
    XCTAssertEqual(state.window, windows[2].reference)
    XCTAssertEqual(state.confidence, .uncertain)
    XCTAssertEqual(
      tracker.resolve(frontmostPID: 30, windows: windows), .unavailable)
  }

  func testOwnApplicationNeverBecomesTarget() {
    var tracker = FocusTracker(ownPID: ownPID)
    let windows = [
      window(1, pid: ownPID, frame: rect(0, 0, 300, 300)),
      window(2, pid: 10, frame: rect(0, 0, 500, 400)),
    ]
    _ = tracker.resolve(frontmostPID: 10, windows: windows)
    let state = tracker.resolve(frontmostPID: ownPID, windows: windows)
    XCTAssertEqual(state.window, windows[1].reference)
    XCTAssertEqual(state.confidence, .uncertain)
  }

  func testFreezeKeepsTargetUntilUnfrozen() {
    var tracker = FocusTracker(ownPID: ownPID)
    let windows = [
      window(1, pid: 10, frame: rect(0, 0, 500, 400)),
      window(2, pid: 20, frame: rect(100, 100, 500, 400)),
    ]
    _ = tracker.resolve(frontmostPID: 20, windows: windows)
    tracker.freeze()
    var state = tracker.resolve(frontmostPID: 10, windows: windows)
    XCTAssertEqual(state.window, windows[1].reference)
    tracker.unfreeze()
    state = tracker.resolve(frontmostPID: 10, windows: windows)
    XCTAssertEqual(state.window, windows[0].reference)
  }

  func testFrozenTargetIsDroppedWhenItsWindowDisappears() {
    var tracker = FocusTracker(ownPID: ownPID)
    let windows = [window(1, pid: 10, frame: rect(0, 0, 500, 400))]
    _ = tracker.resolve(frontmostPID: 10, windows: windows)
    tracker.freeze()
    XCTAssertEqual(tracker.resolve(frontmostPID: 10, windows: []), .unavailable)
    XCTAssertEqual(tracker.resolve(frontmostPID: 10, windows: windows), .unavailable)
  }
}
