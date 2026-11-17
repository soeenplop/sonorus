import Contracts
import Foundation

public enum DesktopFixtures {
  public static let primaryID = DisplayID(rawValue: "fixture-primary")
  public static let secondaryID = DisplayID(rawValue: "fixture-secondary")
  public static let focused = WindowReference(windowID: 101, ownerPID: 1001, generation: 1)
  public static let background = WindowReference(windowID: 102, ownerPID: 1002, generation: 1)

  public static func overlappingWindows(revision: UInt64 = 1) -> DesktopSnapshot {
    DesktopSnapshot(
      revision: revision,
      displays: [
        DisplaySnapshot(
          id: primaryID, runtimeID: 1, name: "Primary",
          frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
        DisplaySnapshot(
          id: secondaryID, runtimeID: 2, name: "Secondary",
          frame: ScreenRect(x: -1920, y: -100, width: 1920, height: 1080), scale: 1),
      ],
      windows: [
        WindowSnapshot(
          reference: focused, ownerBundleID: "fixture.editor",
          frame: ScreenRect(x: 100, y: 100, width: 800, height: 600)),
        WindowSnapshot(
          reference: background, ownerBundleID: "fixture.browser",
          frame: ScreenRect(x: -200, y: 50, width: 1000, height: 700)),
      ],
      focusedWindow: focused, focusConfidence: .uncertain)
  }
}
