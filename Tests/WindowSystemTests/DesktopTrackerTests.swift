import Contracts
import XCTest

@testable import WindowSystem

@MainActor
final class DesktopTrackerTests: XCTestCase {
  private let ownPID: Int32 = 999
  private var windows: FakeWindowSource!
  private var focus: FakeFocusSource!
  private var events: FakeEventSource!
  private var timers: ManualTimers!
  private var displays: FakeDisplays!
  private var separateSpaces = false
  private var tracker: DesktopTracker!

  private let poll = 0.1
  private let burst = 1.0 / 60

  override func setUp() async throws {
    windows = FakeWindowSource()
    focus = FakeFocusSource()
    events = FakeEventSource()
    timers = ManualTimers()
    displays = FakeDisplays([primaryDisplay])
    windows.onScreen = [
      cgEntry(1, pid: 1, owner: "Window Server", layer: 24, frame: rect(0, 0, 1440, 30)),
      cgEntry(50, pid: ownPID, layer: 0, frame: rect(0, 0, 1440, 900)),
      cgEntry(10, pid: 10, frame: rect(100, 100, 600, 400)),
      cgEntry(20, pid: 20, frame: rect(300, 200, 600, 400)),
    ]
    windows.bundles = [10: "fixture.editor", 20: "fixture.browser"]
    focus.pid = 10
    tracker = DesktopTracker(
      displays: displays, windowSource: windows, focusSource: focus, events: events,
      timers: timers, separateSpaces: { [unowned self] in self.separateSpaces }, ownPID: ownPID)
  }

  override func tearDown() async throws {
    tracker.stop()
  }

  private func reference(_ id: UInt32) -> WindowReference? {
    tracker.currentSnapshot?.windows.first { $0.reference.windowID == id }?.reference
  }

  func testStartPublishesConsistentSnapshot() async throws {
    try await tracker.start()
    let snapshot = try XCTUnwrap(tracker.currentSnapshot)
    XCTAssertEqual(snapshot.revision, 1)
    XCTAssertEqual(snapshot.displays, [primaryDisplay])
    XCTAssertEqual(snapshot.windows.map(\.reference.windowID), [1, 10, 20])
    XCTAssertEqual(snapshot.windows.map(\.isSystemUI), [true, false, false])
    XCTAssertEqual(snapshot.windows[1].ownerBundleID, "fixture.editor")
    XCTAssertEqual(snapshot.focusedWindow, reference(10))
    XCTAssertEqual(snapshot.focusConfidence, .uncertain)
    XCTAssertTrue(events.isStarted)
    XCTAssertEqual(timers.active(poll).count, 1)
  }

  func testPublishesOnlyChangedContentWithIncreasingRevision() async throws {
    try await tracker.start()
    var iterator = tracker.updates().makeAsyncIterator()
    let first = await iterator.next()
    XCTAssertEqual(first?.revision, 1)

    timers.fire(poll)
    timers.fire(poll)
    XCTAssertEqual(tracker.currentSnapshot?.revision, 1)

    windows.onScreen[2] = cgEntry(10, pid: 10, frame: rect(110, 100, 600, 400))
    focus.pid = 10
    timers.fire(poll)
    let second = await iterator.next()
    XCTAssertEqual(second?.revision, 2)
    XCTAssertEqual(second?.windows[1].frame, rect(110, 100, 600, 400))
    XCTAssertEqual(second?.focusedWindow?.windowID, 10)
  }

  func testDisplayChangesArePublished() async throws {
    try await tracker.start()
    displays.displays = [primaryDisplay, leftDisplay]
    events.send(.displaysChanged)
    XCTAssertEqual(tracker.currentSnapshot?.displays, [primaryDisplay, leftDisplay])
    XCTAssertEqual(tracker.currentSnapshot?.revision, 2)
  }

  func testSpaceChangeRefreshesImmediatelyAndBursts() async throws {
    try await tracker.start()
    windows.onScreen = [cgEntry(30, pid: 30, frame: rect(0, 0, 800, 600))]
    focus.pid = 30
    events.send(.spaceChanged)
    XCTAssertEqual(tracker.currentSnapshot?.windows.map(\.reference.windowID), [30])
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow?.windowID, 30)
    XCTAssertEqual(timers.active(burst).count, 1)
  }

  func testBurstRunsForHalfASecondAndRestartsOnNewEvents() async throws {
    try await tracker.start()
    events.send(.applicationActivated)
    XCTAssertEqual(timers.active(burst).count, 1)
    for _ in 0..<20 { timers.fire(burst) }
    events.send(.applicationActivated)
    XCTAssertEqual(timers.active(burst).count, 1, "a running burst is extended, not duplicated")
    var ticks = 0
    while timers.fire(burst) > 0 { ticks += 1 }
    XCTAssertEqual(ticks, 30)
  }

  func testBurstPicksUpLateRaisedWindow() async throws {
    try await tracker.start()
    // Focus already moved to window 20, but the window list still shows the old order.
    focus.pid = 20
    events.send(.applicationActivated)
    XCTAssertEqual(tracker.currentSnapshot?.windows.map(\.reference.windowID), [1, 10, 20])
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow?.windowID, 20)
    windows.onScreen = [windows.onScreen[0], windows.onScreen[3], windows.onScreen[2]]
    timers.fire(burst)
    XCTAssertEqual(tracker.currentSnapshot?.windows.map(\.reference.windowID), [1, 20, 10])
  }

  func testWindowListChangesDoNotStartBurst() async throws {
    try await tracker.start()
    events.send(.windowsChanged)
    XCTAssertEqual(timers.active(burst).count, 0)
  }

  func testIdlePollsSlowlyWithoutBursts() async throws {
    try await tracker.start()
    tracker.isIdle = true
    XCTAssertEqual(timers.active(poll).count, 0)
    XCTAssertEqual(timers.active(1).count, 1)
    events.send(.applicationActivated)
    XCTAssertEqual(timers.active(burst).count, 0)

    windows.onScreen.removeLast()
    tracker.isIdle = false
    XCTAssertEqual(
      tracker.currentSnapshot?.windows.map(\.reference.windowID), [1, 10],
      "leaving idle refreshes at once")
    XCTAssertEqual(timers.active(1).count, 0)
    XCTAssertEqual(timers.active(poll).count, 1)
  }

  func testIdleStopsRunningBurst() async throws {
    try await tracker.start()
    events.send(.applicationActivated)
    tracker.isIdle = true
    XCTAssertEqual(timers.active(burst).count, 0)
  }

  func testHiddenWindowsAreRecheckedEveryTwoSeconds() async throws {
    try await tracker.start()
    let minimized = windows.onScreen.removeLast()
    windows.hidden = [minimized]
    timers.fire(poll)
    let calls = windows.describeCalls
    XCTAssertTrue(tracker.knownWindows.contains { $0.windowID == 20 })

    windows.hidden = []  // closed while minimized
    for _ in 0..<18 { timers.fire(poll) }
    XCTAssertEqual(windows.describeCalls, calls)
    XCTAssertTrue(tracker.knownWindows.contains { $0.windowID == 20 })
    timers.fire(poll)
    XCTAssertEqual(windows.describeCalls, calls + 1)
    XCTAssertFalse(tracker.knownWindows.contains { $0.windowID == 20 })
  }

  func testWorkspaceEventsRecheckHiddenWindows() async throws {
    try await tracker.start()
    windows.hidden = [windows.onScreen.removeLast()]
    timers.fire(poll)
    let calls = windows.describeCalls
    windows.hidden = []
    events.send(.windowsChanged)
    XCTAssertEqual(windows.describeCalls, calls + 1)
    XCTAssertFalse(tracker.knownWindows.contains { $0.windowID == 20 })
  }

  func testFreezeKeepsTargetWhileOwnUIIsActive() async throws {
    try await tracker.start()
    let editor = reference(10)
    tracker.beginFocusFreeze()
    focus.pid = 20
    timers.fire(poll)
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow, editor)

    // Window changes are still published while frozen.
    windows.onScreen.removeLast()
    timers.fire(poll)
    XCTAssertEqual(tracker.currentSnapshot?.windows.map(\.reference.windowID), [1, 10])
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow, editor)

    windows.onScreen.append(cgEntry(20, pid: 20, frame: rect(300, 200, 600, 400)))
    await tracker.endFocusFreeze()
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow?.windowID, 20)
    XCTAssertEqual(timers.active(burst).count, 1)
  }

  func testOwnFrontmostApplicationKeepsTarget() async throws {
    try await tracker.start()
    focus.pid = ownPID
    timers.fire(poll)
    XCTAssertEqual(tracker.currentSnapshot?.focusedWindow?.windowID, 10)
    XCTAssertFalse(
      tracker.currentSnapshot?.windows.contains { $0.reference.ownerPID == ownPID } ?? true)
  }

  func testSeparateSpacesClipVisibleFrames() async throws {
    displays.displays = [primaryDisplay, leftDisplay]
    windows.onScreen = [cgEntry(10, pid: 10, frame: rect(-200, 100, 600, 400))]
    focus.pid = 10
    separateSpaces = true
    try await tracker.start()
    XCTAssertEqual(tracker.currentSnapshot?.windows.first?.frame, rect(0, 100, 400, 400))
    XCTAssertEqual(tracker.currentSnapshot?.focusConfidence, .uncertain)
  }

  func testClosedAndReopenedWindowIDGetsNewGeneration() async throws {
    try await tracker.start()
    let old = try XCTUnwrap(reference(20))
    let entry = windows.onScreen.removeLast()
    timers.fire(poll)
    windows.onScreen.append(entry)
    timers.fire(poll)
    let new = try XCTUnwrap(reference(20))
    XCTAssertGreaterThan(new.generation, old.generation)
  }

  func testBundleIDsAreCachedPerProcess() async throws {
    try await tracker.start()
    let lookups = windows.bundleLookups
    for _ in 0..<5 { timers.fire(poll) }
    XCTAssertEqual(windows.bundleLookups, lookups)
  }

  func testStopReleasesEverything() async throws {
    try await tracker.start()
    var iterator = tracker.updates().makeAsyncIterator()
    _ = await iterator.next()
    events.send(.applicationActivated)
    tracker.stop()
    XCTAssertFalse(events.isStarted)
    XCTAssertTrue(timers.handles.allSatisfy(\.isCancelled))
    let end = await iterator.next()
    XCTAssertNil(end)

    windows.onScreen = []
    tracker.refresh()
    XCTAssertEqual(tracker.currentSnapshot?.windows.count, 3, "no refresh after stop")
  }
}
