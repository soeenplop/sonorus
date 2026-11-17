import Contracts
import TestSupport
import XCTest

@testable import Selection

final class RegionSelectionTests: XCTestCase {
  typealias S = SelectionScenario

  private func regionEngine(draft: SelectionDraft = SelectionDraft()) -> SelectionEngine {
    S.engine(mode: .regions, draft: draft)
  }

  private func region(
    _ display: DisplayID, _ rect: ScreenRect, in frame: ScreenRect, enabled: Bool = true
  ) -> FocusRegion {
    FocusRegion(displayID: display, rect: rect.normalized(in: frame), isEnabled: enabled)
  }

  // MARK: Creation

  func testDragCreatesRegionRelativeToItsDisplayAndSelectsIt() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(144, 90), to: S.point(720, 450))

    let created = try XCTUnwrap(engine.draft.regions.first)
    XCTAssertEqual(engine.draft.regions.count, 1)
    XCTAssertEqual(created.displayID, S.primary)
    XCTAssertTrue(created.isEnabled)
    XCTAssertEqual(created.rect.x, 0.1, accuracy: 1e-9)
    XCTAssertEqual(created.rect.y, 0.1, accuracy: 1e-9)
    XCTAssertEqual(created.rect.width, 0.4, accuracy: 1e-9)
    XCTAssertEqual(created.rect.height, 0.4, accuracy: 1e-9)
    XCTAssertEqual(engine.selectedRegionID, created.id)
    XCTAssertEqual(engine.mode, .regions, "stays in region mode for more rectangles")
  }

  func testDraggingUpAndLeftNormalizesTheRectangle() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(720, 450), to: S.point(144, 90))
    let created = try XCTUnwrap(engine.draft.regions.first)
    assertFrame(
      S.frame(of: created, in: S.primaryFrame), ScreenRect(x: 144, y: 90, width: 576, height: 360))
  }

  func testLivePreviewReportsSizeWhileDragging() {
    var engine = regionEngine()
    engine.pointerDown(at: S.point(100, 100))
    engine.pointerDragged(to: S.point(740, 460))
    let preview = engine.scene.preview
    XCTAssertEqual(preview?.displayID, S.primary)
    XCTAssertEqual(preview?.sizeLabel, "640 × 360")
    XCTAssertTrue(engine.draft.regions.isEmpty, "nothing is committed before release")
    engine.pointerUp(at: S.point(740, 460))
    XCTAssertNil(engine.scene.preview)
  }

  func testTinyDragOrClickCreatesNoRegion() {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(100, 100), to: S.point(110, 300))  // too narrow
    S.drag(&engine, from: S.point(100, 100), to: S.point(300, 108))  // too short
    engine.click(at: S.point(500, 500))
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }

  func testSeveralRegionsOnOneDisplay() {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(100, 100), to: S.point(300, 300))
    S.drag(&engine, from: S.point(600, 100), to: S.point(900, 300))
    S.drag(&engine, from: S.point(100, 500), to: S.point(400, 800))
    XCTAssertEqual(engine.draft.regions.count, 3)
    XCTAssertEqual(Set(engine.draft.regions.map(\.displayID)), [S.primary])
    XCTAssertEqual(Set(engine.draft.regions.map(\.id)).count, 3)
  }

  func testRegionsOnDifferentDisplaysUseNegativeOriginDisplayCorrectly() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(100, 100), to: S.point(300, 300))
    // Secondary starts at x = -1920, y = -100.
    S.drag(&engine, from: S.point(-1920 + 192, -100 + 108), to: S.point(-1920 + 960, -100 + 540))

    XCTAssertEqual(engine.draft.regions.map(\.displayID), [S.primary, S.secondary])
    let onSecondary = engine.draft.regions[1]
    XCTAssertEqual(onSecondary.rect.x, 0.1, accuracy: 1e-9)
    XCTAssertEqual(onSecondary.rect.y, 0.1, accuracy: 1e-9)
    XCTAssertEqual(onSecondary.rect.width, 0.4, accuracy: 1e-9)
    XCTAssertEqual(onSecondary.rect.height, 0.4, accuracy: 1e-9)
    assertFrame(
      S.frame(of: onSecondary, in: S.secondaryFrame),
      ScreenRect(x: -1728, y: 8, width: 768, height: 432))
    assertFrame(
      try XCTUnwrap(engine.scene.regions.last).frame,
      ScreenRect(x: -1728, y: 8, width: 768, height: 432))
  }

  func testDragIsClampedToDisplayWhereItStarted() throws {
    var engine = regionEngine()
    // Start on primary, drag far past its right/bottom edge and onto nothing.
    S.drag(&engine, from: S.point(1200, 700), to: S.point(2500, 2000))
    let created = try XCTUnwrap(engine.draft.regions.first)
    XCTAssertEqual(created.displayID, S.primary)
    assertFrame(
      S.frame(of: created, in: S.primaryFrame), ScreenRect(x: 1200, y: 700, width: 240, height: 200)
    )
    XCTAssertLessThanOrEqual(created.rect.x + created.rect.width, 1 + 1e-12)
    XCTAssertLessThanOrEqual(created.rect.y + created.rect.height, 1 + 1e-12)
  }

  func testDragFromSecondaryTowardPrimaryStaysOnSecondary() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(-300, 100), to: S.point(500, 300))  // crosses x == 0
    let created = try XCTUnwrap(engine.draft.regions.first)
    XCTAssertEqual(created.displayID, S.secondary)
    assertFrame(
      S.frame(of: created, in: S.secondaryFrame),
      ScreenRect(x: -300, y: 100, width: 300, height: 200))
  }

  func testDragLeftAndUpPastDisplayOriginClampsToZero() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(200, 200), to: S.point(-500, -500))
    let created = try XCTUnwrap(engine.draft.regions.first)
    XCTAssertEqual(created.displayID, S.primary)
    XCTAssertEqual(created.rect.x, 0, accuracy: 1e-12)
    XCTAssertEqual(created.rect.y, 0, accuracy: 1e-12)
  }

  func testStartingOutsideEveryDisplayCreatesNothing() {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(5000, 5000), to: S.point(5200, 5200))
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }

  // MARK: Move, resize

  private func engineWithOneRegion() throws -> (SelectionEngine, UUID) {
    let seed = region(
      S.primary, ScreenRect(x: 200, y: 200, width: 400, height: 300), in: S.primaryFrame)
    var engine = regionEngine(draft: SelectionDraft(regions: [seed]))
    engine.click(at: S.point(400, 350))  // select it
    XCTAssertEqual(engine.selectedRegionID, seed.id)
    return (engine, seed.id)
  }

  private func frame(_ engine: SelectionEngine, _ id: UUID) throws -> ScreenRect {
    let region = try XCTUnwrap(engine.draft.regions.first { $0.id == id })
    return S.frame(of: region, in: S.primaryFrame)
  }

  func testDraggingRegionBodyMovesIt() throws {
    var (engine, id) = try engineWithOneRegion()
    S.drag(&engine, from: S.point(400, 350), to: S.point(450, 330))
    assertFrame(try frame(engine, id), ScreenRect(x: 250, y: 180, width: 400, height: 300))
    XCTAssertEqual(engine.draft.regions.count, 1)
  }

  func testMoveIsClampedToDisplayAndKeepsSize() throws {
    var (engine, id) = try engineWithOneRegion()
    S.drag(&engine, from: S.point(400, 350), to: S.point(5000, 5000))
    assertFrame(try frame(engine, id), ScreenRect(x: 1040, y: 600, width: 400, height: 300))
    S.drag(&engine, from: S.point(1200, 750), to: S.point(-3000, -3000))
    assertFrame(try frame(engine, id), ScreenRect(x: 0, y: 0, width: 400, height: 300))
  }

  func testSmallPointerJitterOnClickDoesNotMove() throws {
    var (engine, id) = try engineWithOneRegion()
    engine.pointerDown(at: S.point(400, 350))
    engine.pointerDragged(to: S.point(402, 351))
    engine.pointerUp(at: S.point(402, 351))
    assertFrame(try frame(engine, id), ScreenRect(x: 200, y: 200, width: 400, height: 300))
  }

  func testResizeWithEveryHandle() throws {
    let cases: [(RegionHandle, ScreenPoint, ScreenRect)] = [
      (.topLeft, S.point(200, 200), ScreenRect(x: 230, y: 220, width: 370, height: 280)),
      (.top, S.point(400, 200), ScreenRect(x: 200, y: 220, width: 400, height: 280)),
      (.topRight, S.point(600, 200), ScreenRect(x: 200, y: 220, width: 430, height: 280)),
      (.right, S.point(600, 350), ScreenRect(x: 200, y: 200, width: 430, height: 300)),
      (.bottomRight, S.point(600, 500), ScreenRect(x: 200, y: 200, width: 430, height: 320)),
      (.bottom, S.point(400, 500), ScreenRect(x: 200, y: 200, width: 400, height: 320)),
      (.bottomLeft, S.point(200, 500), ScreenRect(x: 230, y: 200, width: 370, height: 320)),
      (.left, S.point(200, 350), ScreenRect(x: 230, y: 200, width: 370, height: 300)),
    ]
    for (handle, start, expected) in cases {
      var (engine, id) = try engineWithOneRegion()
      XCTAssertEqual(engine.cursor(at: start), .resize(handle))
      S.drag(&engine, from: start, to: S.point(start.x + 30, start.y + 20))
      assertFrame(try frame(engine, id), expected, accuracy: 1e-6)
      XCTAssertEqual(engine.draft.regions.count, 1, "\(handle) must not create a region")
    }
  }

  func testResizeIsClampedToDisplayAndMinimumSize() throws {
    var (engine, id) = try engineWithOneRegion()
    S.drag(&engine, from: S.point(600, 500), to: S.point(9000, 9000))
    assertFrame(try frame(engine, id), ScreenRect(x: 200, y: 200, width: 1240, height: 700))

    // Dragging the right edge far left cannot cross the left edge.
    S.drag(&engine, from: S.point(1440, 550), to: S.point(-500, 550))
    assertFrame(
      try frame(engine, id),
      ScreenRect(x: 200, y: 200, width: SelectionEngine.minimumRegionSize, height: 700))
  }

  func testRegionNeverLeavesNormalizedRange() throws {
    var (engine, id) = try engineWithOneRegion()
    S.drag(&engine, from: S.point(600, 500), to: S.point(9000, 9000))
    let rect = try XCTUnwrap(engine.draft.regions.first { $0.id == id }?.rect)
    XCTAssertGreaterThanOrEqual(rect.x, 0)
    XCTAssertGreaterThanOrEqual(rect.y, 0)
    XCTAssertLessThanOrEqual(rect.x + rect.width, 1 + 1e-12)
    XCTAssertLessThanOrEqual(rect.y + rect.height, 1 + 1e-12)
  }

  func testMoveOnSecondaryDisplayWithNegativeOrigin() throws {
    let seed = region(
      S.secondary, ScreenRect(x: -1500, y: 0, width: 400, height: 300), in: S.secondaryFrame)
    var engine = regionEngine(draft: SelectionDraft(regions: [seed]))
    S.drag(&engine, from: S.point(-1300, 100), to: S.point(-9000, -9000))
    let moved = try XCTUnwrap(engine.draft.regions.first)
    assertFrame(
      S.frame(of: moved, in: S.secondaryFrame),
      ScreenRect(x: -1920, y: -100, width: 400, height: 300))
    XCTAssertEqual(moved.displayID, S.secondary)
  }

  // MARK: Delete, disable

  func testDeleteRemovesOnlySelectedRegion() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(100, 100), to: S.point(300, 300))
    S.drag(&engine, from: S.point(600, 100), to: S.point(900, 300))
    let keep = engine.draft.regions[0]
    XCTAssertTrue(engine.deleteSelectedRegion())
    XCTAssertEqual(engine.draft.regions, [keep])
    XCTAssertNil(engine.selectedRegionID)
    XCTAssertFalse(engine.deleteSelectedRegion(), "nothing selected anymore")
  }

  func testDisableAndEnableSingleRegion() throws {
    var engine = regionEngine()
    S.drag(&engine, from: S.point(100, 100), to: S.point(300, 300))
    S.drag(&engine, from: S.point(600, 100), to: S.point(900, 300))
    XCTAssertTrue(engine.toggleSelectedRegionEnabled())
    XCTAssertEqual(engine.draft.regions.map(\.isEnabled), [true, false])
    XCTAssertEqual(engine.scene.regions.map(\.isEnabled), [true, false])
    XCTAssertTrue(engine.toggleSelectedRegionEnabled())
    XCTAssertEqual(engine.draft.regions.map(\.isEnabled), [true, true])
  }

  func testDisabledRegionCanStillBeMovedAndDeleted() throws {
    var (engine, id) = try engineWithOneRegion()
    engine.toggleSelectedRegionEnabled()
    S.drag(&engine, from: S.point(400, 350), to: S.point(500, 350))
    assertFrame(try frame(engine, id), ScreenRect(x: 300, y: 200, width: 400, height: 300))
    XCTAssertTrue(engine.deleteSelectedRegion())
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }

  func testEditingActionsRequireRegionModeAndSelection() throws {
    var (engine, _) = try engineWithOneRegion()
    engine.setMode(.windows)
    XCTAssertFalse(engine.deleteSelectedRegion())
    XCTAssertFalse(engine.toggleSelectedRegionEnabled())
    XCTAssertEqual(engine.draft.regions.count, 1)
  }

  func testClickOnEmptyAreaClearsSelection() throws {
    var (engine, _) = try engineWithOneRegion()
    engine.click(at: S.point(1300, 800))
    XCTAssertNil(engine.selectedRegionID)
    XCTAssertEqual(engine.draft.regions.count, 1)
  }

  // MARK: Overlap

  private func overlappingPair() -> (SelectionEngine, bottom: FocusRegion, top: FocusRegion) {
    let bottom = region(
      S.primary, ScreenRect(x: 100, y: 100, width: 400, height: 400), in: S.primaryFrame)
    let top = region(
      S.primary, ScreenRect(x: 300, y: 300, width: 400, height: 400), in: S.primaryFrame)
    return (regionEngine(draft: SelectionDraft(regions: [bottom, top])), bottom, top)
  }

  func testOverlapClickPrefersTopmostRegion() {
    var (engine, bottom, top) = overlappingPair()
    engine.click(at: S.point(400, 400))  // in both
    XCTAssertEqual(engine.selectedRegionID, top.id)
    engine.click(at: S.point(150, 150))  // only bottom
    XCTAssertEqual(engine.selectedRegionID, bottom.id)
  }

  func testOverlappingRegionsAreEditedIndependently() throws {
    var (engine, bottom, top) = overlappingPair()
    engine.click(at: S.point(150, 150))  // select bottom
    S.drag(&engine, from: S.point(150, 150), to: S.point(170, 130))
    let after = engine.draft.regions
    assertFrame(
      S.frame(of: after[0], in: S.primaryFrame), ScreenRect(x: 120, y: 80, width: 400, height: 400))
    XCTAssertEqual(after[1], top, "the other region is untouched")
    XCTAssertEqual(after[0].id, bottom.id)
  }

  func testSelectedRegionKeepsPriorityInsideOverlap() throws {
    var (engine, bottom, top) = overlappingPair()
    engine.click(at: S.point(150, 150))  // select bottom
    // (400, 400) lies in both; the selected bottom region is moved, not the top one.
    S.drag(&engine, from: S.point(400, 400), to: S.point(420, 400))
    XCTAssertEqual(engine.selectedRegionID, bottom.id)
    XCTAssertEqual(engine.draft.regions[1], top)
    assertFrame(
      S.frame(of: engine.draft.regions[0], in: S.primaryFrame),
      ScreenRect(x: 120, y: 100, width: 400, height: 400))
  }

  func testClickWithoutDragCyclesThroughOverlapStack() {
    var (engine, bottom, top) = overlappingPair()
    engine.click(at: S.point(400, 400))
    XCTAssertEqual(engine.selectedRegionID, top.id)
    engine.click(at: S.point(400, 400))
    XCTAssertEqual(engine.selectedRegionID, bottom.id)
    engine.click(at: S.point(400, 400))
    XCTAssertEqual(engine.selectedRegionID, top.id)
  }

  func testTabReachesCompletelyCoveredRegion() {
    let inner = region(
      S.primary, ScreenRect(x: 300, y: 300, width: 50, height: 50), in: S.primaryFrame)
    let outer = region(
      S.primary, ScreenRect(x: 100, y: 100, width: 600, height: 600), in: S.primaryFrame)
    var engine = regionEngine(draft: SelectionDraft(regions: [inner, outer]))
    engine.selectNextRegion()
    XCTAssertEqual(engine.selectedRegionID, inner.id)
    engine.selectNextRegion()
    XCTAssertEqual(engine.selectedRegionID, outer.id)
    engine.selectNextRegion()
    XCTAssertEqual(engine.selectedRegionID, inner.id)
    engine.selectNextRegion(backward: true)
    XCTAssertEqual(engine.selectedRegionID, outer.id)
  }

  func testOptionDragStartsNewRegionInsideExistingOne() {
    var (engine, _, _) = overlappingPair()
    S.drag(&engine, from: S.point(350, 350), to: S.point(450, 450), startsNewRegion: true)
    XCTAssertEqual(engine.draft.regions.count, 3)
  }

  func testOverlappingRegionsAreNotMergedInDraft() {
    var (engine, _, _) = overlappingPair()
    S.drag(&engine, from: S.point(350, 350), to: S.point(450, 450), startsNewRegion: true)
    XCTAssertEqual(engine.scene.regions.count, 3)
  }

  // MARK: Display loss

  func testRegionOfMissingDisplayIsKeptButNotEditable() {
    let gone = FocusRegion(
      displayID: DisplayID(rawValue: "unplugged"),
      rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    var engine = regionEngine(draft: SelectionDraft(regions: [gone]))
    XCTAssertTrue(engine.scene.regions.isEmpty)
    engine.click(at: S.point(400, 400))
    engine.selectNextRegion()
    XCTAssertNil(engine.selectedRegionID)
    XCTAssertEqual(engine.draft.regions, [gone])
    engine.confirm()
    XCTAssertEqual(engine.outcome, .confirmed(SelectionDraft(regions: [gone])))
  }

  // MARK: Handles and cursor

  func testSelectedRegionHandlesAreExposedInScene() throws {
    let (engine, _) = try engineWithOneRegion()
    let handles = Dictionary(
      uniqueKeysWithValues: engine.scene.handles.map { ($0.handle, $0.position) })
    XCTAssertEqual(handles.count, 8)
    XCTAssertEqual(handles[.topLeft], S.point(200, 200))
    XCTAssertEqual(handles[.bottomRight], S.point(600, 500))
    XCTAssertEqual(handles[.top], S.point(400, 200))
    XCTAssertEqual(handles[.left], S.point(200, 350))
  }

  func testCursorHints() throws {
    var (engine, _) = try engineWithOneRegion()
    XCTAssertEqual(engine.cursor(at: S.point(1000, 800)), .crosshair)
    XCTAssertEqual(engine.cursor(at: S.point(400, 350)), .move)
    XCTAssertEqual(engine.cursor(at: S.point(603, 497)), .resize(.bottomRight))
    engine.setMode(.windows)
    XCTAssertEqual(engine.cursor(at: S.point(400, 350)), .crosshair)
  }

  func testTinyRegionStillAllowsMovingFromItsCenter() {
    let tiny = region(
      S.primary, ScreenRect(x: 300, y: 300, width: 16, height: 16), in: S.primaryFrame)
    var engine = regionEngine(draft: SelectionDraft(regions: [tiny]))
    engine.click(at: S.point(308, 308))
    XCTAssertEqual(engine.cursor(at: S.point(308, 308)), .move)
  }
}
