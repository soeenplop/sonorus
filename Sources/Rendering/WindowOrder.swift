import Contracts
import CoreGraphics
import Foundation
import Geometry

/// One entry of the live WindowServer list, front to back.
struct LiveWindow: Equatable, Sendable {
  let id: UInt32
  let ownerPID: Int32
  let level: Int
  let frame: ScreenRect
  let alpha: Double

  init(id: UInt32, ownerPID: Int32, level: Int = 0, frame: ScreenRect, alpha: Double = 1) {
    self.id = id
    self.ownerPID = ownerPID
    self.level = level
    self.frame = frame
    self.alpha = alpha
  }

  /// Parses one `CGWindowListCopyWindowInfo` dictionary.
  init?(info: [String: Any]) {
    guard let number = info[kCGWindowNumber as String] as? NSNumber,
      let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
      let layer = info[kCGWindowLayer as String] as? NSNumber,
      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: bounds)
    else { return nil }
    self.init(
      id: number.uint32Value, ownerPID: pid.int32Value, level: layer.intValue,
      frame: ScreenRect(
        x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
      alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
  }
}

/// Live-order checks for surfaces ordered directly below the anchor window.
/// Only foreign, visible normal-level windows on the display matter: other
/// levels stay above or below normal-level surfaces either way.
struct AnchorOrder: Equatable, Sendable {
  let window: UInt32
  let group: Set<UInt32>
  let ownProcessID: Int32

  init(_ anchor: RenderAnchor, ownProcessID: Int32) {
    window = anchor.window.windowID
    group = Set(anchor.group.map(\.windowID)).union([anchor.window.windowID])
    self.ownProcessID = ownProcessID
  }

  /// Before ordering: the anchor is on screen and only group members lie in
  /// front of it on this display.
  func allowsAnchoring(on display: ScreenRect, in windows: [LiveWindow]) -> Bool {
    guard let anchorIndex = windows.firstIndex(where: { $0.id == window }) else { return false }
    return onlyGroup(in: windows[..<anchorIndex], on: display)
  }

  /// After ordering: the surface lies below the anchor and only group
  /// members (and own surfaces) lie in front of it on this display.
  func isDirectlyBelow(surface: UInt32, on display: ScreenRect, in windows: [LiveWindow])
    -> Bool
  {
    guard let surfaceIndex = windows.firstIndex(where: { $0.id == surface }),
      let anchorIndex = windows.firstIndex(where: { $0.id == window }),
      anchorIndex < surfaceIndex
    else { return false }
    return onlyGroup(in: windows[..<surfaceIndex], on: display)
  }

  private func onlyGroup(in windows: ArraySlice<LiveWindow>, on display: ScreenRect) -> Bool {
    windows.allSatisfy { window in
      group.contains(window.id) || window.ownerPID == ownProcessID || window.level != 0
        || window.alpha < 0.05 || !window.frame.intersects(display)
    }
  }
}
