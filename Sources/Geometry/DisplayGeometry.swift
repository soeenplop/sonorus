import Contracts

/// Conversions between display-relative normalized rectangles and global
/// Quartz points. Scale factors do not apply here: both sides are points and
/// pixel conversion belongs to the rendering boundary.
public enum DisplayGeometry {
  /// Clips a normalized rectangle to 0...1 on both axes. Returns nil when the
  /// input is non-finite, has no positive size or lies completely outside.
  public static func validated(_ rect: NormalizedRect) -> NormalizedRect? {
    let values = [rect.x, rect.y, rect.width, rect.height]
    guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return nil }
    if rect.x >= 0, rect.y >= 0, rect.x + rect.width <= 1, rect.y + rect.height <= 1 {
      return rect
    }
    let minX = min(1, max(0, rect.x))
    let minY = min(1, max(0, rect.y))
    let maxX = min(1, max(0, rect.x + rect.width))
    let maxY = min(1, max(0, rect.y + rect.height))
    guard maxX > minX, maxY > minY else { return nil }
    return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// Global rectangle for a normalized rectangle on a display with `frame`.
  /// The normalized input is validated and clipped first.
  public static func screenRect(for rect: NormalizedRect, in frame: ScreenRect) -> ScreenRect? {
    guard frame.isUsable, let valid = validated(rect) else { return nil }
    let result = ScreenRect(
      x: frame.x + valid.x * frame.width, y: frame.y + valid.y * frame.height,
      width: valid.width * frame.width, height: valid.height * frame.height)
    return clipped(result, to: frame)
  }

  public static func screenRect(for rect: NormalizedRect, on display: DisplaySnapshot)
    -> ScreenRect?
  {
    screenRect(for: rect, in: display.frame)
  }

  /// Normalized rectangle for the part of a global rectangle inside `frame`.
  public static func normalizedRect(for rect: ScreenRect, in frame: ScreenRect) -> NormalizedRect? {
    guard let visible = clipped(rect, to: frame) else { return nil }
    let result = NormalizedRect(
      x: (visible.x - frame.x) / frame.width, y: (visible.y - frame.y) / frame.height,
      width: visible.width / frame.width, height: visible.height / frame.height)
    return validated(result)
  }

  public static func normalizedRect(for rect: ScreenRect, on display: DisplaySnapshot)
    -> NormalizedRect?
  {
    normalizedRect(for: rect, in: display.frame)
  }

  /// Part of `rect` inside the display frame, or nil when they do not overlap.
  public static func clipped(_ rect: ScreenRect, to frame: ScreenRect) -> ScreenRect? {
    rect.intersection(frame)
  }

  public static func clipped(_ region: ScreenRegion, to frame: ScreenRect) -> ScreenRegion {
    region.intersection(frame)
  }
}
