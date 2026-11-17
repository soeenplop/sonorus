import Contracts
import TestSupport
import XCTest

@testable import Selection

final class SelectionDisplayLayoutTests: XCTestCase {
  private let displays = DesktopFixtures.overlappingWindows().displays

  func testIdenticalLayoutIsNotAChange() {
    let current = SelectionDisplayLayout.entries(of: displays.reversed())
    XCTAssertFalse(SelectionDisplayLayout.hasChanged(from: displays, to: current))
  }

  func testChangedFrameIsAChange() {
    var moved = displays
    moved[1] = DisplaySnapshot(
      id: moved[1].id, runtimeID: moved[1].runtimeID, name: moved[1].name,
      frame: ScreenRect(x: -1920, y: -50, width: 1920, height: 1080), scale: moved[1].scale)
    XCTAssertTrue(
      SelectionDisplayLayout.hasChanged(
        from: displays, to: SelectionDisplayLayout.entries(of: moved)))
  }

  func testAddedOrRemovedDisplayIsAChange() {
    let removed = SelectionDisplayLayout.entries(of: [displays[0]])
    XCTAssertTrue(SelectionDisplayLayout.hasChanged(from: displays, to: removed))
    var added = displays
    added.append(
      DisplaySnapshot(
        id: DisplayID(rawValue: "extra"), runtimeID: 3, name: "Extra",
        frame: ScreenRect(x: 1440, y: 0, width: 800, height: 600), scale: 1))
    XCTAssertTrue(
      SelectionDisplayLayout.hasChanged(
        from: displays, to: SelectionDisplayLayout.entries(of: added)))
  }

  func testSwappedRuntimeIDsAreAChange() {
    let swapped = [
      DisplaySnapshot(
        id: displays[0].id, runtimeID: 2, name: "A", frame: displays[0].frame, scale: 2),
      DisplaySnapshot(
        id: displays[1].id, runtimeID: 1, name: "B", frame: displays[1].frame, scale: 1),
    ]
    XCTAssertTrue(
      SelectionDisplayLayout.hasChanged(
        from: displays, to: SelectionDisplayLayout.entries(of: swapped)))
  }
}
