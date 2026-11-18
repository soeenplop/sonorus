import Contracts
import TestSupport
import XCTest

@testable import Selection

final class WindowAndDisplaySelectionTests: XCTestCase {
  typealias S = SelectionScenario

  private func window(
    _ id: UInt32, pid: Int32 = 1, frame: ScreenRect, isOnScreen: Bool = true,
    isSystemUI: Bool = false
  ) -> WindowSnapshot {
    WindowSnapshot(
      reference: WindowReference(windowID: id, ownerPID: pid, generation: 1), frame: frame,
      isOnScreen: isOnScreen, isSystemUI: isSystemUI)
  }

  // MARK: Window hover

  func testHoverPicksFrontMostWindowWhereWindowsOverlap() {
    var engine = S.engine(mode: .windows)
    engine.pointerMoved(to: S.point(150, 150))  // inside focused and background
    XCTAssertEqual(engine.hoveredWindow, S.focused)

    engine.pointerMoved(to: S.point(-100, 100))  // background only
    XCTAssertEqual(engine.hoveredWindow, S.background)

    engine.pointerMoved(to: S.point(1300, 800))  // empty desktop
    XCTAssertNil(engine.hoveredWindow)
  }

  func testPointerOverToolbarClearsHover() {
    var engine = S.engine(mode: .windows)
    engine.pointerMoved(to: S.point(150, 150))
    XCTAssertEqual(engine.hoveredWindow, S.focused)

    engine.apply(.left)
    XCTAssertNil(engine.hoveredWindow)
    XCTAssertNil(engine.pointer)
    XCTAssertTrue(engine.scene.windows.allSatisfy { !$0.isHovered })
  }

  func testHoverFollowsSnapshotOrderNotWindowSize() {
    let small = window(1, frame: ScreenRect(x: 0, y: 0, width: 100, height: 100))
    let large = window(2, frame: ScreenRect(x: 0, y: 0, width: 500, height: 500))

    var largeInFront = S.engine(mode: .windows, desktop: S.desktop(windows: [large, small]))
    largeInFront.pointerMoved(to: S.point(50, 50))
    XCTAssertEqual(largeInFront.hoveredWindow, large.reference)

    var smallInFront = S.engine(mode: .windows, desktop: S.desktop(windows: [small, large]))
    smallInFront.pointerMoved(to: S.point(50, 50))
    XCTAssertEqual(smallInFront.hoveredWindow, small.reference)
  }

  func testHoverIgnoresSystemUIOffScreenAndOwnWindows() {
    let ownOverlay = window(
      9, pid: S.ownPID, frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900))
    let menuBar = window(
      8, frame: ScreenRect(x: 0, y: 0, width: 1440, height: 40), isSystemUI: true)
    let hidden = window(
      7, frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900), isOnScreen: false)
    let content = window(1, frame: ScreenRect(x: 0, y: 0, width: 800, height: 600))
    let desktop = S.desktop(windows: [ownOverlay, menuBar, hidden, content])

    var engine = S.engine(mode: .windows, desktop: desktop, excluding: [S.ownPID])
    engine.pointerMoved(to: S.point(10, 10))  // below menu bar, overlay and hidden window
    XCTAssertEqual(engine.hoveredWindow, content.reference)

    engine.pointerMoved(to: S.point(1200, 700))  // only own overlay and hidden window there
    XCTAssertNil(engine.hoveredWindow)
  }

  func testWindowWithUnusableFrameIsNeverHit() {
    let broken = window(5, frame: ScreenRect(x: 0, y: 0, width: 0, height: 0))
    var engine = S.engine(mode: .windows, desktop: S.desktop(windows: [broken]))
    engine.pointerMoved(to: S.point(0, 0))
    XCTAssertNil(engine.hoveredWindow)
  }

  func testHoverIsOnlyTrackedInWindowMode() {
    var engine = S.engine(mode: .displays)
    engine.pointerMoved(to: S.point(150, 150))
    XCTAssertNil(engine.hoveredWindow)
    XCTAssertEqual(engine.hoveredDisplay, S.primary)
  }

  // MARK: Window selection

  func testClickTogglesWindowSelection() {
    var engine = S.engine(mode: .windows)
    engine.click(at: S.point(150, 150))
    XCTAssertEqual(engine.draft.windows, [S.focused])
    engine.click(at: S.point(150, 150))
    XCTAssertEqual(engine.draft.windows, [])
  }

  func testWindowsAccumulateAcrossClicks() {
    var engine = S.engine(mode: .windows)
    engine.click(at: S.point(150, 150))
    engine.click(at: S.point(-100, 100))
    XCTAssertEqual(engine.draft.windows, [S.focused, S.background])
    engine.click(at: S.point(-100, 100))
    XCTAssertEqual(engine.draft.windows, [S.focused])
  }

  func testClickOnEmptyDesktopChangesNothing() {
    var engine = S.engine(mode: .windows, draft: SelectionDraft(windows: [S.focused]))
    engine.click(at: S.point(1300, 800))
    XCTAssertEqual(engine.draft.windows, [S.focused])
  }

  func testReleaseOverDifferentWindowDoesNotToggle() {
    var engine = S.engine(mode: .windows)
    engine.pointerDown(at: S.point(150, 150))
    engine.pointerUp(at: S.point(-100, 100))
    XCTAssertEqual(engine.draft.windows, [])
  }

  func testPreexistingSelectionIsKeptAndShownInScene() {
    var engine = S.engine(mode: .windows, draft: SelectionDraft(windows: [S.background]))
    engine.pointerMoved(to: S.point(150, 150))
    let marks = engine.scene.windows
    XCTAssertEqual(marks.map(\.reference), [S.background, S.focused])  // back to front
    XCTAssertEqual(marks.map(\.isSelected), [true, false])
    XCTAssertEqual(marks.map(\.isHovered), [false, true])
  }

  func testStaleWindowReferencesStayInDraftButAreNotDrawn() {
    let stale = WindowReference(windowID: 999, ownerPID: 1, generation: 3)
    let engine = S.engine(mode: .windows, draft: SelectionDraft(windows: [stale]))
    XCTAssertEqual(engine.draft.windows, [stale])
    XCTAssertTrue(engine.scene.windows.isEmpty)
  }

  // MARK: Displays

  func testDisplayHoverUsesNegativeOriginDisplay() {
    var engine = S.engine(mode: .displays)
    engine.pointerMoved(to: S.point(-1000, -50))
    XCTAssertEqual(engine.hoveredDisplay, S.secondary)
    engine.pointerMoved(to: S.point(700, 400))
    XCTAssertEqual(engine.hoveredDisplay, S.primary)
    engine.pointerMoved(to: S.point(-1, -101))  // above both displays
    XCTAssertNil(engine.hoveredDisplay)
  }

  func testSharedDisplayEdgeBelongsToOneDisplay() {
    var engine = S.engine(mode: .displays)
    engine.pointerMoved(to: S.point(0, 100))  // x == 0 is primary, secondary ends at 0
    XCTAssertEqual(engine.hoveredDisplay, S.primary)
    engine.pointerMoved(to: S.point(-0.5, 100))
    XCTAssertEqual(engine.hoveredDisplay, S.secondary)
  }

  func testDisplayClicksToggleAndMultiSelect() {
    var engine = S.engine(mode: .displays)
    engine.click(at: S.point(700, 400))
    engine.click(at: S.point(-1000, 0))
    XCTAssertEqual(engine.draft.displays, [S.primary, S.secondary])
    engine.click(at: S.point(700, 400))
    XCTAssertEqual(engine.draft.displays, [S.secondary])
  }

  func testDisplaySceneShowsLabelsHoverAndExistingSelection() {
    var engine = S.engine(mode: .displays, draft: SelectionDraft(displays: [S.secondary]))
    engine.pointerMoved(to: S.point(700, 400))
    let marks = engine.scene.displays
    XCTAssertEqual(marks.map(\.name), ["Primary", "Secondary"])
    XCTAssertEqual(marks.map(\.isHovered), [true, false])
    XCTAssertEqual(marks.map(\.isSelected), [false, true])
  }

  // MARK: Mode switching

  func testSwitchingModeKeepsOtherSelectionsAndRefreshesHover() {
    var engine = S.engine(mode: .windows)
    engine.click(at: S.point(150, 150))
    engine.setMode(.displays)
    XCTAssertNil(engine.hoveredWindow)
    XCTAssertEqual(engine.hoveredDisplay, S.primary)
    engine.click(at: S.point(150, 150))
    engine.setMode(.windows)
    XCTAssertEqual(engine.draft.windows, [S.focused])
    XCTAssertEqual(engine.draft.displays, [S.primary])
    XCTAssertEqual(engine.hoveredWindow, S.focused)
  }

  func testSwitchingModeDropsGestureInProgress() {
    var engine = S.engine(mode: .regions)
    engine.pointerDown(at: S.point(100, 100))
    engine.pointerDragged(to: S.point(300, 300))
    XCTAssertNotNil(engine.scene.preview)
    engine.setMode(.windows)
    engine.pointerUp(at: S.point(300, 300))
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }
}

final class SelectionAccessibilityTests: XCTestCase {
  typealias S = SelectionScenario

  func testSummaryCountsTheSelectionOfTheCurrentMode() {
    var engine = S.engine(mode: .windows)
    XCTAssertEqual(engine.scene.selectionSummary, "No window selected")
    engine.click(at: S.point(150, 150))
    XCTAssertEqual(engine.scene.selectionSummary, "1 window selected")
    engine.click(at: S.point(-100, 100))
    XCTAssertEqual(engine.scene.selectionSummary, "2 windows selected")

    engine.setMode(.displays)
    engine.click(at: S.point(700, 400))
    XCTAssertEqual(engine.scene.selectionSummary, "1 display selected")

    engine.setMode(.regions)
    XCTAssertEqual(engine.scene.selectionSummary, "No region")
    S.drag(&engine, from: S.point(100, 100), to: S.point(400, 400))
    XCTAssertEqual(engine.scene.selectionSummary, "1 region")
  }
}
