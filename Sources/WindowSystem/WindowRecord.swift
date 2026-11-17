import Contracts
import CoreGraphics
import Foundation

/// One parsed `CGWindowListCopyWindowInfo` entry. `frame` is the full window
/// frame in global Quartz points, exactly as the window server reports it.
struct WindowRecord: Equatable, Sendable {
  let windowID: UInt32
  let ownerPID: Int32
  let ownerName: String?
  let layer: Int
  let frame: ScreenRect
  let alpha: Double
  let isOnScreen: Bool

  init(
    windowID: UInt32, ownerPID: Int32, ownerName: String? = nil, layer: Int = 0,
    frame: ScreenRect, alpha: Double = 1, isOnScreen: Bool = true
  ) {
    self.windowID = windowID
    self.ownerPID = ownerPID
    self.ownerName = ownerName
    self.layer = layer
    self.frame = frame
    self.alpha = alpha
    self.isOnScreen = isOnScreen
  }
}

enum WindowListParser {
  /// Keeps the input order (front to back) and drops malformed entries.
  static func parse(_ entries: [[String: Any]]) -> [WindowRecord] {
    entries.compactMap(record)
  }

  static func record(_ info: [String: Any]) -> WindowRecord? {
    guard let id = number(info[kCGWindowNumber as String]),
      let pid = number(info[kCGWindowOwnerPID as String]),
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let x = number(bounds["X"]), let y = number(bounds["Y"]),
      let width = number(bounds["Width"]), let height = number(bounds["Height"])
    else { return nil }
    return WindowRecord(
      windowID: id.uint32Value, ownerPID: pid.int32Value,
      ownerName: info[kCGWindowOwnerName as String] as? String,
      layer: number(info[kCGWindowLayer as String])?.intValue ?? 0,
      frame: ScreenRect(
        x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue),
      alpha: number(info[kCGWindowAlpha as String])?.doubleValue ?? 1,
      isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
  }

  private static func number(_ value: Any?) -> NSNumber? {
    value as? NSNumber
  }
}

extension ScreenRect {
  var maxX: Double { x + width }
  var maxY: Double { y + height }
  var area: Double { isUsable ? width * height : 0 }

  func intersection(_ other: ScreenRect) -> ScreenRect? {
    let left = Swift.max(x, other.x)
    let top = Swift.max(y, other.y)
    let right = Swift.min(maxX, other.maxX)
    let bottom = Swift.min(maxY, other.maxY)
    let rect = ScreenRect(x: left, y: top, width: right - left, height: bottom - top)
    return rect.isUsable ? rect : nil
  }

  func contains(_ other: ScreenRect) -> Bool {
    other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
  }
}
