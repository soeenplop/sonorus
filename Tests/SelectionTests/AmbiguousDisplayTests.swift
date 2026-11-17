import Contracts
import TestSupport
import XCTest

@testable import Selection

/// Two identical monitors report the same persistent `DisplayID`; only the
/// runtime ID tells them apart. Those displays must not be selectable.
final class AmbiguousDisplayTests: XCTestCase {
  private typealias S = SelectionScenario

  private static let twinID = DisplayID(rawValue: "fixture-twin")
  private static let twinAFrame = ScreenRect(x: 1440, y: 0, width: 1000, height: 800)
  private static let twinBFrame = ScreenRect(x: 2440, y: 0, width: 1000, height: 800)

  private static let desktop = DesktopSnapshot(
    revision: 1,
    displays: [
      DisplaySnapshot(
        id: S.primary, runtimeID: 1, name: "Primary", frame: S.primaryFrame, scale: 2),
      DisplaySnapshot(
        id: twinID, runtimeID: 10, name: "Twin", frame: twinAFrame, scale: 1),
      DisplaySnapshot(
        id: twinID, runtimeID: 11, name: "Twin", frame: twinBFrame, scale: 1),
    ],
    windows: [], focusedWindow: nil, focusConfidence: .unavailable)

  private func engine(mode: SelectionMode, draft: SelectionDraft = SelectionDraft())
    -> SelectionEngine
  {
    S.engine(mode: mode, draft: draft, desktop: Self.desktop)
  }

  // MARK: Detection

  func testOnlyDuplicatedIDsAreAmbiguous() {
    XCTAssertEqual(engine(mode: .displays).ambiguousDisplayIDs, [Self.twinID])
    XCTAssertTrue(S.engine(mode: .displays).ambiguousDisplayIDs.isEmpty)
  }

  func testSceneMarksAmbiguousDisplaysAndKeepsRuntimeIDs() {
    let marks = engine(mode: .displays).scene.displays
    XCTAssertEqual(marks.map(\.runtimeID), [1, 10, 11])
    XCTAssertEqual(marks.map(\.isAmbiguous), [false, true, true])
    XCTAssertFalse(SelectionScene.ambiguousDisplayLabel.isEmpty)
  }

  // MARK: Display mode

  func testAmbiguousDisplayIsNeitherHoveredNorSelected() {
    var engine = engine(mode: .displays)
    engine.pointerMoved(to: S.point(1500, 100))
    XCTAssertNil(engine.hoveredDisplay)
    engine.click(at: S.point(1500, 100))
    engine.click(at: S.point(2500, 100))
    XCTAssertTrue(engine.draft.displays.isEmpty)
    XCTAssertEqual(engine.scene.displays.map(\.isHovered), [false, false, false])
  }

  func testUnambiguousDisplayStaysSelectableNextToAmbiguousOnes() {
    var engine = engine(mode: .displays)
    engine.click(at: S.point(700, 400))
    XCTAssertEqual(engine.draft.displays, [S.primary])
    XCTAssertEqual(engine.scene.displays.map(\.isHovered), [true, false, false])
  }

  func testStoredSelectionOfAmbiguousIDIsKeptButNotShown() {
    var engine = engine(mode: .displays, draft: SelectionDraft(displays: [Self.twinID, S.primary]))
    XCTAssertEqual(engine.scene.displays.map(\.isSelected), [true, false, false])
    engine.click(at: S.point(1500, 100))
    engine.click(at: S.point(700, 400))
    engine.confirm()
    guard case .confirmed(let draft)? = engine.outcome else { return XCTFail("not confirmed") }
    XCTAssertEqual(draft.displays, [Self.twinID])
  }

  // MARK: Region mode

  func testRegionCannotBeDrawnOnAmbiguousDisplay() {
    var engine = engine(mode: .regions)
    S.drag(&engine, from: S.point(1500, 100), to: S.point(1900, 500))
    XCTAssertTrue(engine.draft.regions.isEmpty)
    XCTAssertNil(engine.selectedRegionID)
    XCTAssertNil(engine.scene.preview)
    S.drag(&engine, from: S.point(2500, 100), to: S.point(2900, 500))
    XCTAssertTrue(engine.draft.regions.isEmpty)
  }

  func testRegionCanStillBeDrawnOnUnambiguousDisplay() {
    var engine = engine(mode: .regions)
    S.drag(&engine, from: S.point(100, 100), to: S.point(400, 300))
    XCTAssertEqual(engine.draft.regions.count, 1)
    XCTAssertEqual(engine.draft.regions.first?.displayID, S.primary)
  }

  func testRegionOfAmbiguousIDIsKeptButNotShownOrEditable() {
    let stored = FocusRegion(
      displayID: Self.twinID, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
    var engine = engine(mode: .regions, draft: SelectionDraft(regions: [stored]))
    XCTAssertTrue(engine.editableRegions.isEmpty)
    XCTAssertTrue(engine.scene.regions.isEmpty)

    // Press inside where the region would be on either twin; nothing moves.
    S.drag(&engine, from: S.point(1600, 200), to: S.point(1700, 300))
    S.drag(&engine, from: S.point(2600, 200), to: S.point(2700, 300))
    engine.selectNextRegion()
    XCTAssertNil(engine.selectedRegionID)
    engine.confirm()
    guard case .confirmed(let draft)? = engine.outcome else { return XCTFail("not confirmed") }
    XCTAssertEqual(draft.regions, [stored])
  }

  // MARK: Window mode

  func testWindowModeIsUnaffected() {
    let window = WindowSnapshot(
      reference: S.focused, ownerBundleID: "fixture.editor",
      frame: ScreenRect(x: 1500, y: 100, width: 400, height: 300))
    let desktop = DesktopSnapshot(
      revision: 1, displays: Self.desktop.displays, windows: [window], focusedWindow: nil,
      focusConfidence: .unavailable)
    var engine = S.engine(mode: .windows, desktop: desktop)
    engine.click(at: S.point(1600, 200))
    XCTAssertEqual(engine.draft.windows, [S.focused])
  }
}
