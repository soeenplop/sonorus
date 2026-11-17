import Foundation

/// Persistent identity, not the transient CGDirectDisplayID. Adapters must
/// report ambiguity instead of silently attaching rules to another display.
public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Session identity. Generation distinguishes a reused window ID after close.
/// This reference must not be persisted as a cross-launch window exception.
public struct WindowReference: Codable, Hashable, Sendable {
  public let windowID: UInt32
  public let ownerPID: Int32
  public let generation: UInt64

  public init(windowID: UInt32, ownerPID: Int32, generation: UInt64) {
    self.windowID = windowID
    self.ownerPID = ownerPID
    self.generation = generation
  }
}

public struct DisplaySnapshot: Equatable, Sendable {
  public let id: DisplayID
  public let runtimeID: UInt32
  public let name: String
  public let frame: ScreenRect
  public let scale: Double

  public init(id: DisplayID, runtimeID: UInt32, name: String, frame: ScreenRect, scale: Double) {
    self.id = id
    self.runtimeID = runtimeID
    self.name = name
    self.frame = frame
    self.scale = scale
  }
}

/// `level` is the CoreGraphics window level; 0 is the normal level. `frame` is
/// the visible frame: when displays have separate Spaces, adapters clip it to
/// the display that currently shows the window. Adapters omit nearly
/// transparent windows (alpha < 0.05, e.g. while closing).
public struct WindowSnapshot: Equatable, Sendable {
  public let reference: WindowReference
  public let ownerBundleID: String?
  public let frame: ScreenRect
  public let level: Int
  public let isOnScreen: Bool
  public let isSystemUI: Bool

  public init(
    reference: WindowReference, ownerBundleID: String? = nil, frame: ScreenRect,
    level: Int = 0, isOnScreen: Bool = true, isSystemUI: Bool = false
  ) {
    self.reference = reference
    self.ownerBundleID = ownerBundleID
    self.frame = frame
    self.level = level
    self.isOnScreen = isOnScreen
    self.isSystemUI = isSystemUI
  }
}

/// Focus is guessed from the window order, so a found window is `uncertain`.
public enum FocusConfidence: Equatable, Sendable {
  case uncertain
  case unavailable
}

/// Immutable, internally consistent view of the desktop. Windows are ordered
/// front to back, include occluding system surfaces where available, and exclude
/// Sonorus overlays. Revision does NOT synchronize this with capture frames.
public struct DesktopSnapshot: Equatable, Sendable {
  public let revision: UInt64
  public let displays: [DisplaySnapshot]
  public let windows: [WindowSnapshot]
  public let focusedWindow: WindowReference?
  public let focusConfidence: FocusConfidence
  public let associatedWindows: Set<WindowReference>

  public init(
    revision: UInt64, displays: [DisplaySnapshot], windows: [WindowSnapshot],
    focusedWindow: WindowReference?, focusConfidence: FocusConfidence,
    associatedWindows: Set<WindowReference> = []
  ) {
    self.revision = revision
    self.displays = displays
    self.windows = windows
    self.focusedWindow = focusedWindow
    self.focusConfidence = focusConfidence
    self.associatedWindows = associatedWindows
  }
}
