import Contracts

/// Minimal rectangle math in Quartz points. Selection depends only on Contracts,
/// so it keeps its own small helpers instead of importing Geometry.
extension ScreenRect {
  var minX: Double { x }
  var minY: Double { y }
  var maxX: Double { x + width }
  var maxY: Double { y + height }

  /// Half-open containment, so a point on a shared display edge belongs to one display only.
  func containsHalfOpen(_ point: ScreenPoint) -> Bool {
    point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
  }

  /// Closed containment, used for windows and regions where edge pixels still count as a hit.
  func contains(_ point: ScreenPoint) -> Bool {
    point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
  }

  func clamped(_ point: ScreenPoint) -> ScreenPoint {
    ScreenPoint(
      x: Swift.min(Swift.max(point.x, minX), maxX),
      y: Swift.min(Swift.max(point.y, minY), maxY))
  }

  init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// Rectangle spanned by two corners in any order.
  init(from a: ScreenPoint, to b: ScreenPoint) {
    self.init(
      minX: Swift.min(a.x, b.x), minY: Swift.min(a.y, b.y),
      maxX: Swift.max(a.x, b.x), maxY: Swift.max(a.y, b.y))
  }

  /// Converts to coordinates relative to `display`, kept inside 0...1.
  func normalized(in display: ScreenRect) -> NormalizedRect {
    let left = Swift.min(Swift.max((minX - display.minX) / display.width, 0), 1)
    let top = Swift.min(Swift.max((minY - display.minY) / display.height, 0), 1)
    let width = Swift.min(Swift.max(self.width / display.width, 0), 1 - left)
    let height = Swift.min(Swift.max(self.height / display.height, 0), 1 - top)
    return NormalizedRect(x: left, y: top, width: width, height: height)
  }
}

extension NormalizedRect {
  /// Global rectangle for this display-relative rectangle.
  func absolute(in display: ScreenRect) -> ScreenRect {
    ScreenRect(
      x: display.x + x * display.width, y: display.y + y * display.height,
      width: width * display.width, height: height * display.height)
  }
}

extension ScreenPoint {
  /// Largest axis distance; handle hit zones are squares, not circles.
  func chebyshevDistance(to other: ScreenPoint) -> Double {
    Swift.max(abs(x - other.x), abs(y - other.y))
  }
}
