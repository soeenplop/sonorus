import AppKit
import CoreGraphics
import QuartzCore

@MainActor
final class SystemWindowList: WindowListReading {
  let ownProcessID = ProcessInfo.processInfo.processIdentifier

  /// The main display is the one at the global origin.
  var primaryDisplayHeight: Double? {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    return bounds.height > 0 ? bounds.height : nil
  }

  func frontToBackWindows() -> [LiveWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return info.compactMap(LiveWindow.init(info:))
  }
}

@MainActor
final class MainQueueScheduler: TransitionScheduling {
  private final class TaskAction: ScheduledAction {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
  }

  var now: Double { CACurrentMediaTime() }

  func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    -> any ScheduledAction
  {
    let scheduled = TaskAction()
    scheduled.task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(max(0, delay)))
      guard !Task.isCancelled else { return }
      action()
    }
    return scheduled
  }
}

@MainActor
final class WorkspaceAccessibility: AccessibilityDisplayOptions {
  var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
