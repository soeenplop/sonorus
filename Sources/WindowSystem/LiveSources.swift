import AppKit
import Contracts
import CoreGraphics

/// `CGWindowListCopyWindowInfo` and friends. Reading the list needs no
/// permission; window titles are not used.
@MainActor
final class CGWindowListSource: WindowListSource {
  func onScreenWindows() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
  }

  func describeWindows(_ ids: [UInt32]) -> [[String: Any]] {
    guard !ids.isEmpty else { return [] }
    // The API expects raw CGWindowID values stored as pointers, not CFNumbers.
    var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &values, values.count, nil) else { return [] }
    return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
  }

  func bundleIdentifier(for pid: Int32) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }
}

/// Focus from `NSWorkspace`: the frontmost application. Needs no permission.
@MainActor
final class WorkspaceFocusSource: FocusSource {
  func frontmostApplicationPID() -> Int32? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
  }
}

/// Workspace and display notifications; polling covers everything else.
@MainActor
final class WorkspaceEventSource: DesktopEventSource {
  private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
  private var handler: (@MainActor (DesktopEvent) -> Void)?

  func start(_ handler: @escaping @MainActor (DesktopEvent) -> Void) {
    stop()
    self.handler = handler
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.didActivateApplicationNotification) {
      $0.handler?(.applicationActivated)
    }
    observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.handler?(.spaceChanged) }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      observe(workspace, name) { $0.handler?(.wake) }
    }
    for name in [
      NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      observe(workspace, name) { $0.handler?(.windowsChanged) }
    }
    observe(.default, NSApplication.didChangeScreenParametersNotification) {
      $0.handler?(.displaysChanged)
    }
  }

  func stop() {
    for (center, observer) in observers { center.removeObserver(observer) }
    observers.removeAll()
    handler = nil
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ action: @escaping @MainActor (WorkspaceEventSource) -> Void
  ) {
    let observer = center.addObserver(forName: name, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        action(self)
      }
    }
    observers.append((center, observer))
  }
}

/// Timers in the common run loop modes, so polling continues while menus track.
@MainActor
final class RunLoopTimers: TimerScheduling {
  private final class Handle: RepeatingTimer {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
  }

  func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> any RepeatingTimer
  {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { action() }
    }
    // Lets the system coalesce wake-ups; a tenth of the interval is not visible.
    timer.tolerance = interval * 0.1
    RunLoop.main.add(timer, forMode: .common)
    return Handle(timer)
  }
}
