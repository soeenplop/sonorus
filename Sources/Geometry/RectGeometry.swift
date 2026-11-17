import Contracts

extension ScreenRect {
  public var minX: Double { x }
  public var minY: Double { y }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var area: Double { isUsable ? width * height : 0 }

  /// Builds a rectangle from edges; returns nil for empty or non-finite results.
  public static func fromEdges(minX: Double, minY: Double, maxX: Double, maxY: Double)
    -> ScreenRect?
  {
    let rect = ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    return rect.isUsable ? rect : nil
  }

  /// Edges rounded to multiples of `step`. With a power-of-two step and
  /// coordinates of realistic magnitude, every later edge computation on the
  /// result is exact, so derived pieces share edges without slivers or overlap.
  public func snapped(toGrid step: Double = ScreenRect.exactGrid) -> ScreenRect? {
    guard isUsable, step.isFinite, step > 0 else { return nil }
    func snap(_ value: Double) -> Double { (value / step).rounded() * step }
    return .fromEdges(minX: snap(minX), minY: snap(minY), maxX: snap(maxX), maxY: snap(maxY))
  }

  /// 1/256 point: finer than any physical pixel, exactly representable.
  public static let exactGrid = 1.0 / 256

  /// Overlapping area with positive size. Touching edges do not intersect.
  public func intersection(_ other: ScreenRect) -> ScreenRect? {
    guard isUsable, other.isUsable else { return nil }
    return .fromEdges(
      minX: Swift.max(minX, other.minX), minY: Swift.max(minY, other.minY),
      maxX: Swift.min(maxX, other.maxX), maxY: Swift.min(maxY, other.maxY))
  }

  public func intersects(_ other: ScreenRect) -> Bool {
    intersection(other) != nil
  }

  public func contains(_ other: ScreenRect) -> Bool {
    guard isUsable, other.isUsable else { return false }
    return minX <= other.minX && minY <= other.minY && maxX >= other.maxX
      && maxY >= other.maxY
  }

  /// This rectangle minus `other` as at most four non-overlapping pieces:
  /// full-width bands above and below, then the left and right remainders.
  public func subtracting(_ other: ScreenRect) -> [ScreenRect] {
    guard isUsable else { return [] }
    guard let cut = intersection(other) else { return [self] }
    return [
      ScreenRect.fromEdges(minX: minX, minY: minY, maxX: maxX, maxY: cut.minY),
      ScreenRect.fromEdges(minX: minX, minY: cut.maxY, maxX: maxX, maxY: maxY),
      ScreenRect.fromEdges(minX: minX, minY: cut.minY, maxX: cut.minX, maxY: cut.maxY),
      ScreenRect.fromEdges(minX: cut.maxX, minY: cut.minY, maxX: maxX, maxY: cut.maxY),
    ].compactMap { $0 }
  }
}
