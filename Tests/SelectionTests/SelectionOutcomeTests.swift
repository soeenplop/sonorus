import Contracts
import TestSupport
import XCTest

@testable import Selection

final class SelectionOutcomeTests: XCTestCase {
  typealias S = SelectionScenario

  private let existing = FocusRegion(
    displayID: SelectionScenario.primary,
    rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

  private func initialDraft() -> SelectionDraft {
    SelectionDraft(windows: [S.background], displays: [S.secondary], regions: [existing])
  }

  func testConfirmReturnsEditedDraft() {
    var engine = S.engine(mode: .windows, draft: initialDraft())
    engine.click(at: S.point(150, 150))
    engine.setMode(.regions)
    S.drag(&engine, from: S.point(600, 600), to: S.point(900, 800))
    engine.confirm()

    guard case .confirmed(let draft, let mode)? = engine.outcome else {
      return XCTFail("expected confirmed outcome, got \(String(describing: engine.outcome))")
    }
    XCTAssertEqual(mode, .regions)
    XCTAssertEqual(draft.windows, [S.background, S.focused])
    XCTAssertEqual(draft.displays, [S.secondary])
    XCTAssertEqual(draft.regions.count, 2)
    XCTAssertEqual(draft.regions.first, existing)
  }

  func testCancelDiscardsAllChangesAndRestoresPreviousDraft() {
    var engine = S.engine(mode: .windows, draft: initialDraft())
    engine.click(at: S.point(150, 150))
    engine.setMode(.displays)
    engine.click(at: S.point(700, 400))
    engine.setMode(.regions)
    S.drag(&engine, from: S.point(600, 600), to: S.point(900, 800))
    engine.cancel()

    XCTAssertEqual(engine.outcome, .cancelled)
    XCTAssertEqual(engine.draft, initialDraft())
  }

  func testConfirmWithoutChangesReturnsInitialDraft() {
    var engine = S.engine(mode: .regions, draft: initialDraft())
    engine.confirm()
    XCTAssertEqual(engine.outcome, .confirmed(initialDraft(), mode: .regions))
  }

  func testConfirmDropsRectangleStillBeingDragged() {
    var engine = S.engine(mode: .regions)
    engine.pointerDown(at: S.point(100, 100))
    engine.pointerDragged(to: S.point(400, 400))
    engine.confirm()
    XCTAssertEqual(engine.outcome, .confirmed(SelectionDraft(), mode: .regions))
    engine.pointerUp(at: S.point(400, 400))
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }

  func testCancelMidDragDiscardsEvenMovedRegion() {
    let start = initialDraft()
    var engine = S.engine(mode: .regions, draft: start)
    engine.click(at: S.point(0.2 * 1440, 0.2 * 900))
    engine.pointerDown(at: S.point(0.2 * 1440, 0.2 * 900))
    engine.pointerDragged(to: S.point(700, 700))
    engine.cancel()
    XCTAssertEqual(engine.draft, start)
    XCTAssertEqual(engine.outcome, .cancelled)
  }

  func testNoInputIsAcceptedAfterFinishing() {
    var confirmed = S.engine(mode: .windows)
    confirmed.confirm()
    confirmed.click(at: S.point(150, 150))
    confirmed.cancel()
    XCTAssertEqual(confirmed.outcome, .confirmed(SelectionDraft(), mode: .windows))
    XCTAssertTrue(confirmed.draft.windows.isEmpty)

    var cancelled = S.engine(mode: .windows)
    cancelled.cancel()
    cancelled.confirm()
    XCTAssertEqual(cancelled.outcome, .cancelled)
  }

  func testSceneOnlyShowsCurrentModeContent() {
    var engine = S.engine(
      mode: .regions,
      draft: SelectionDraft(windows: [S.focused], displays: [S.primary], regions: [existing]))
    XCTAssertTrue(engine.scene.windows.isEmpty)
    XCTAssertEqual(engine.scene.regions.count, 1)
    XCTAssertEqual(engine.scene.displays.map(\.isSelected), [false, false])
    engine.setMode(.displays)
    XCTAssertTrue(engine.scene.regions.isEmpty)
    XCTAssertEqual(engine.scene.displays.map(\.isSelected), [true, false])
  }

  func testCoordinateSpaceConvertsNegativeOriginDisplayToAppKit() {
    let primaryHeight = SelectionCoordinateSpace.primaryHeight(
      of: DesktopFixtures.overlappingWindows().displays)
    XCTAssertEqual(primaryHeight, 900)
    let appKit = SelectionCoordinateSpace.appKitFrame(
      forQuartz: S.secondaryFrame, primaryHeight: 900)
    assertFrame(appKit, ScreenRect(x: -1920, y: -80, width: 1920, height: 1080))
    assertFrame(
      SelectionCoordinateSpace.appKitFrame(forQuartz: S.primaryFrame, primaryHeight: 900),
      S.primaryFrame)

    let local = SelectionCoordinateSpace.localPoint(
      forGlobal: S.point(-1900, -90), in: S.secondaryFrame)
    XCTAssertEqual(local, S.point(20, 10))
    XCTAssertEqual(
      SelectionCoordinateSpace.globalPoint(forLocal: local, in: S.secondaryFrame),
      S.point(-1900, -90))
  }
}
