import Contracts
import TestSupport
import XCTest

@testable import Selection

/// Shared scenario: primary 1440×900 at the origin, secondary 1920×1080 at
/// (-1920, -100). Front to back: `focused`, `background`; background straddles
/// both displays.
enum SelectionScenario {
  static let primary = DesktopFixtures.primaryID
  static let secondary = DesktopFixtures.secondaryID
  static let primaryFrame = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
  static let secondaryFrame = ScreenRect(x: -1920, y: -100, width: 1920, height: 1080)

  static let focused = DesktopFixtures.focused
  static let background = DesktopFixtures.background
  static let ownPID: Int32 = 4242

  static func engine(
    mode: SelectionMode, draft: SelectionDraft = SelectionDraft(),
    desktop: DesktopSnapshot = DesktopFixtures.overlappingWindows(),
    excluding pids: Set<Int32> = []
  ) -> SelectionEngine {
    SelectionEngine(
      request: SelectionRequest(mode: mode, desktop: desktop, draft: draft),
      excludedOwnerPIDs: pids)
  }

  static func desktop(windows: [WindowSnapshot]) -> DesktopSnapshot {
    let base = DesktopFixtures.overlappingWindows()
    return DesktopSnapshot(
      revision: base.revision, displays: base.displays, windows: windows,
      focusedWindow: nil, focusConfidence: .unavailable)
  }

  static func point(_ x: Double, _ y: Double) -> ScreenPoint { ScreenPoint(x: x, y: y) }

  static func drag(
    _ engine: inout SelectionEngine, from start: ScreenPoint, to end: ScreenPoint,
    startsNewRegion: Bool = false
  ) {
    engine.pointerDown(at: start, startsNewRegion: startsNewRegion)
    let steps = 4
    for step in 1...steps {
      let fraction = Double(step) / Double(steps)
      engine.pointerDragged(
        to: ScreenPoint(
          x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
    }
    engine.pointerUp(at: end)
  }

  static func frame(of region: FocusRegion, in display: ScreenRect) -> ScreenRect {
    region.rect.absolute(in: display)
  }
}

func assertFrame(
  _ actual: ScreenRect, _ expected: ScreenRect, accuracy: Double = 1e-6,
  file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x", file: file, line: line)
  XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y", file: file, line: line)
  XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
  XCTAssertEqual(
    actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
}
