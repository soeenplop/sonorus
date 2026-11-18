import Contracts
import Foundation

/// Draw description derived from the engine. Frames are global Quartz points;
/// the presenter translates them into each display's local view coordinates.
struct SelectionScene: Equatable, Sendable {
  struct DisplayMark: Equatable, Sendable {
    let id: DisplayID
    /// Distinguishes displays that share the same persistent `id`.
    let runtimeID: UInt32
    let name: String
    let frame: ScreenRect
    let scale: Double
    /// The persistent `id` is shared with another display, so it cannot be targeted.
    let isAmbiguous: Bool
    let isHovered: Bool
    let isSelected: Bool
  }

  struct WindowMark: Equatable, Sendable {
    let reference: WindowReference
    let frame: ScreenRect
    let isHovered: Bool
    let isSelected: Bool
  }

  struct RegionMark: Equatable, Sendable {
    let id: UUID
    let displayID: DisplayID
    let frame: ScreenRect
    let isEnabled: Bool
    let isSelected: Bool

    var sizeLabel: String { SelectionScene.sizeLabel(for: frame) }
  }

  struct HandleMark: Equatable, Sendable {
    let handle: RegionHandle
    let position: ScreenPoint
  }

  /// Rectangle that is still being dragged out; becomes a region on release.
  struct Preview: Equatable, Sendable {
    let displayID: DisplayID
    let frame: ScreenRect

    var sizeLabel: String { SelectionScene.sizeLabel(for: frame) }
  }

  let mode: SelectionMode
  var displays: [DisplayMark] = []
  var windows: [WindowMark] = []
  var regions: [RegionMark] = []
  var handles: [HandleMark] = []
  var preview: Preview?

  init(mode: SelectionMode) {
    self.mode = mode
  }

  static let ambiguousDisplayLabel = "Not uniquely identified – cannot be selected"

  /// What the overlay is for, spoken by VoiceOver.
  var accessibilityHelp: String {
    let task =
      switch mode {
      case .windows: "Click the windows that should stay sharp."
      case .displays: "Click the displays the effect applies to."
      case .regions: "Drag a rectangle to create a region."
      }
    return task + " Return applies, Esc cancels, 1, 2 and 3 switch the mode."
  }

  /// The current selection in words; announced when it changes.
  var selectionSummary: String {
    switch mode {
    case .windows:
      Self.count(windows.filter(\.isSelected).count, "window", "windows") + " selected"
    case .displays:
      Self.count(displays.filter(\.isSelected).count, "display", "displays")
        + " selected"
    case .regions:
      Self.count(regions.count, "region", "regions")
    }
  }

  private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
    switch value {
    case 0: "No \(singular)"
    case 1: "1 \(singular)"
    default: "\(value) \(plural)"
    }
  }

  static func sizeLabel(for frame: ScreenRect) -> String {
    "\(Int(frame.width.rounded())) × \(Int(frame.height.rounded()))"
  }
}

/// Conversion between the Quartz space of the contracts and AppKit's bottom-left
/// global space, which only the presenter needs at the window boundary.
enum SelectionCoordinateSpace {
  /// `primaryHeight` is the height of the display whose Quartz origin is (0, 0).
  static func appKitFrame(
    forQuartz frame: ScreenRect, primaryHeight: Double
  ) -> ScreenRect {
    ScreenRect(
      x: frame.x, y: primaryHeight - (frame.y + frame.height),
      width: frame.width, height: frame.height)
  }

  /// Local, top-left based coordinates inside the overlay of `display`.
  static func localPoint(forGlobal point: ScreenPoint, in display: ScreenRect) -> ScreenPoint {
    ScreenPoint(x: point.x - display.x, y: point.y - display.y)
  }

  static func globalPoint(forLocal point: ScreenPoint, in display: ScreenRect) -> ScreenPoint {
    ScreenPoint(x: point.x + display.x, y: point.y + display.y)
  }

  static func primaryHeight(of displays: [DisplaySnapshot]) -> Double? {
    displays.first { $0.frame.x == 0 && $0.frame.y == 0 }?.frame.height
  }
}
