import XCTest

@testable import Contracts

final class SelectionApplyTests: XCTestCase {
  private let window = WindowReference(windowID: 1, ownerPID: 1, generation: 1)
  private let display = DisplayID(rawValue: "display")
  private var region: FocusRegion {
    FocusRegion(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayID: display,
      rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
  }

  func testRegionsDrawnAfterSwitchingFromWindowModeAreKept() {
    var session = FocusSession()
    session.apply(
      SelectionDraft(windows: [window], regions: [region]), original: SelectionDraft(),
      startMode: .windows, endMode: .regions)
    XCTAssertEqual(session.exceptions, [window])
    XCTAssertEqual(session.configuration.regions, [region])
    XCTAssertEqual(session.configuration.scope, .regions)
  }

  func testDisplaysPickedBeforeSwitchingToWindowModeAreKept() {
    var session = FocusSession()
    session.apply(
      SelectionDraft(windows: [window], displays: [display]), original: SelectionDraft(),
      startMode: .windows, endMode: .windows)
    XCTAssertEqual(session.exceptions, [window])
    XCTAssertEqual(session.configuration.scope, .displays([display]))
  }

  func testWindowPassWithoutOtherEditsKeepsScope() {
    var session = FocusSession(configuration: FocusConfiguration(scope: .regions))
    session.apply(
      SelectionDraft(windows: [window]), original: SelectionDraft(),
      startMode: .windows, endMode: .windows)
    XCTAssertEqual(session.configuration.scope, .regions)
  }

  func testEmptyDisplaySelectionDoesNotSwitchScope() {
    var session = FocusSession()
    session.apply(
      SelectionDraft(), original: SelectionDraft(), startMode: .displays, endMode: .displays)
    XCTAssertEqual(session.configuration.scope, .allDisplays)
  }

  func testDeselectingEveryDisplayKeepsDisplayScopeEmpty() {
    var session = FocusSession(configuration: FocusConfiguration(scope: .displays([display])))
    session.apply(
      SelectionDraft(), original: SelectionDraft(displays: [display]),
      startMode: .displays, endMode: .displays)
    XCTAssertEqual(session.configuration.scope, .displays([]))
  }

  func testEmptyRegionPassDoesNotSwitchScope() {
    var session = FocusSession()
    session.apply(
      SelectionDraft(), original: SelectionDraft(), startMode: .regions, endMode: .regions)
    XCTAssertEqual(session.configuration.scope, .allDisplays)
  }
}
