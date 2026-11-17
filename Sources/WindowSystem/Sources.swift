import Foundation

/// Raw window-server access. Dictionaries use the `kCGWindow…` keys.
@MainActor
protocol WindowListSource: AnyObject {
  /// On-screen windows without desktop elements, front to back.
  func onScreenWindows() -> [[String: Any]]
  /// Descriptions of the given windows that still exist, on screen or not.
  func describeWindows(_ ids: [UInt32]) -> [[String: Any]]
  func bundleIdentifier(for pid: Int32) -> String?
}

@MainActor
protocol FocusSource: AnyObject {
  func frontmostApplicationPID() -> Int32?
}

enum DesktopEvent: Equatable, Sendable {
  case applicationActivated
  case windowsChanged
  case spaceChanged
  case displaysChanged
  case wake

  /// Events after which the window list keeps changing for a few frames.
  var startsBurst: Bool { self != .windowsChanged }
}

@MainActor
protocol DesktopEventSource: AnyObject {
  func start(_ handler: @escaping @MainActor (DesktopEvent) -> Void)
  func stop()
}

@MainActor
protocol RepeatingTimer: AnyObject {
  func cancel()
}

@MainActor
protocol TimerScheduling: AnyObject {
  func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> any RepeatingTimer
}
