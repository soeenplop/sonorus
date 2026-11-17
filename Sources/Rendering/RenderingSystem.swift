import CoreGraphics

/// Small seams between renderer logic and AppKit, CoreGraphics and private
/// API, so ordering, transitions and masks are testable without windows.

/// Where a surface is ordered: directly below a window at normal level, or
/// above every normal window at normal level + 1.
enum SurfacePosition: Hashable, Sendable {
  case anchored(below: UInt32)
  case overlay

  var isAnchored: Bool {
    if case .anchored = self { return true }
    return false
  }
}

/// One click-through, full-display effect panel.
@MainActor
protocol EffectSurface: AnyObject {
  var windowID: UInt32 { get }
  /// `frame` is in AppKit screen coordinates.
  func setFrame(_ frame: CGRect, scale: Double)
  func order(below windowID: UInt32)
  func orderAboveNormalWindows()
  func hide()
  func setMask(_ mask: SurfaceMask)
  /// Immediate values; removes running animations.
  func setValues(_ values: SurfaceValues)
  /// Render-server keyframes; the model takes the final values at once.
  func animate(_ animation: SurfaceAnimation)
  func close()
}

@MainActor
protocol EffectSurfaceMaking: AnyObject {
  var usesFallbackBlur: Bool { get }
  func makeSurface(frame: CGRect, scale: Double) -> (any EffectSurface)?
  /// Applies layer changes together in one transaction without implicit
  /// animations.
  func performAtomically(_ changes: () -> Void)
}

@MainActor
protocol WindowListReading: AnyObject {
  var ownProcessID: Int32 { get }
  var primaryDisplayHeight: Double? { get }
  /// On-screen windows, front to back.
  func frontToBackWindows() -> [LiveWindow]
}

@MainActor
protocol ScheduledAction: AnyObject {
  func cancel()
}

@MainActor
protocol TransitionScheduling: AnyObject {
  /// Monotonic seconds.
  var now: Double { get }
  func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    -> any ScheduledAction
}

@MainActor
protocol AccessibilityDisplayOptions: AnyObject {
  var reduceMotion: Bool { get }
}
