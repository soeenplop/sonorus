import Contracts
import CoreGraphics
import Foundation

@testable import WindowSystem

/// Synthetic `CGWindowListCopyWindowInfo` entry with the real key names.
func cgEntry(
  _ id: UInt32, pid: Int32, owner: String = "App", layer: Int = 0,
  frame: ScreenRect, alpha: Double = 1, onScreen: Bool = true
) -> [String: Any] {
  var entry: [String: Any] = [
    kCGWindowNumber as String: NSNumber(value: id),
    kCGWindowOwnerPID as String: NSNumber(value: pid),
    kCGWindowOwnerName as String: owner,
    kCGWindowLayer as String: NSNumber(value: layer),
    kCGWindowAlpha as String: NSNumber(value: alpha),
    kCGWindowIsOnscreen as String: onScreen,
    kCGWindowBounds as String: [
      "X": NSNumber(value: frame.x), "Y": NSNumber(value: frame.y),
      "Width": NSNumber(value: frame.width), "Height": NSNumber(value: frame.height),
    ],
  ]
  return entry
}

func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenRect {
  ScreenRect(x: x, y: y, width: width, height: height)
}

@MainActor
final class FakeWindowSource: WindowListSource {
  var onScreen: [[String: Any]] = []
  /// Windows that exist but are not on screen (minimized, other Space).
  var hidden: [[String: Any]] = []
  var bundles: [Int32: String] = [:]
  private(set) var bundleLookups = 0

  func onScreenWindows() -> [[String: Any]] { onScreen }

  func describeWindows(_ ids: [UInt32]) -> [[String: Any]] {
    let wanted = Set(ids)
    return (onScreen + hidden).filter {
      wanted.contains(($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
    }
  }

  func bundleIdentifier(for pid: Int32) -> String? {
    bundleLookups += 1
    return bundles[pid]
  }
}

@MainActor
final class FakeFocusSource: FocusSource {
  var pid: Int32?
  func frontmostApplicationPID() -> Int32? { pid }
}

@MainActor
final class FakeEventSource: DesktopEventSource {
  private var handler: (@MainActor (DesktopEvent) -> Void)?
  private(set) var isStarted = false

  func start(_ handler: @escaping @MainActor (DesktopEvent) -> Void) {
    self.handler = handler
    isStarted = true
  }

  func stop() {
    handler = nil
    isStarted = false
  }

  func send(_ event: DesktopEvent) { handler?(event) }
}

@MainActor
final class ManualTimers: TimerScheduling {
  final class Handle: RepeatingTimer {
    let interval: TimeInterval
    let action: @MainActor () -> Void
    private(set) var isCancelled = false
    init(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
      self.interval = interval
      self.action = action
    }
    func cancel() { isCancelled = true }
  }

  private(set) var handles: [Handle] = []

  func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> any RepeatingTimer
  {
    let handle = Handle(interval, action)
    handles.append(handle)
    return handle
  }

  func active(_ interval: TimeInterval) -> [Handle] {
    handles.filter { !$0.isCancelled && abs($0.interval - interval) < 1e-9 }
  }

  /// Fires every active timer with this interval once; returns how many fired.
  @discardableResult
  func fire(_ interval: TimeInterval) -> Int {
    let due = active(interval)
    for handle in due { handle.action() }
    return due.count
  }
}

@MainActor
final class FakeDisplays: DisplayProviding {
  var displays: [DisplaySnapshot]
  init(_ displays: [DisplaySnapshot]) { self.displays = displays }
  func currentDisplays() -> [DisplaySnapshot] { displays }
}

let primaryDisplay = DisplaySnapshot(
  id: DisplayID(rawValue: "uuid:PRIMARY"), runtimeID: 1, name: "Primary",
  frame: rect(0, 0, 1440, 900), scale: 2)
let leftDisplay = DisplaySnapshot(
  id: DisplayID(rawValue: "uuid:LEFT"), runtimeID: 2, name: "Left",
  frame: rect(-1920, -100, 1920, 1080), scale: 1)
