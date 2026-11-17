import Contracts
import CoreGraphics
import Geometry

/// Effect area of one surface in panel-local AppKit points (origin bottom
/// left, y up). `full` needs no mask layer at all.
enum SurfaceMask: Equatable, Sendable {
  case full
  case rects([CGRect])

  static let empty = SurfaceMask.rects([])

  var isEmpty: Bool { self == .empty }
}

/// Conversion from global Quartz points (top-left origin of the primary
/// display, y down) to AppKit window frames and panel-local mask geometry.
/// Display scale never enters point conversion; it only sets layer
/// resolution at the rendering boundary.
enum RenderGeometry {
  /// Height of the primary display, the one at the Quartz origin.
  static func primaryDisplayHeight(in displays: [DisplaySnapshot]) -> Double? {
    displays.first { $0.frame.x == 0 && $0.frame.y == 0 && $0.frame.isUsable }?.frame.height
  }

  static func appKitFrame(of frame: ScreenRect, primaryDisplayHeight: Double) -> CGRect {
    CGRect(
      x: frame.x, y: primaryDisplayHeight - frame.y - frame.height, width: frame.width,
      height: frame.height)
  }

  /// `rects` clipped to `frame`, relative to its bottom-left corner, y up.
  static func localRects(_ rects: [ScreenRect], in frame: ScreenRect) -> [CGRect] {
    rects.compactMap { rect in
      guard let clipped = rect.intersection(frame) else { return nil }
      return CGRect(
        x: clipped.x - frame.x, y: frame.maxY - clipped.maxY, width: clipped.width,
        height: clipped.height)
    }
  }

  static func mask(for rects: [ScreenRect], in frame: ScreenRect) -> SurfaceMask {
    let local = localRects(rects, in: frame)
    let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
    if local.count == 1, let only = local.first, covers(only, bounds) { return .full }
    return .rects(local)
  }

  /// Disjoint rectangles as one path; nonzero filling equals their union.
  static func path(for rects: [CGRect]) -> CGPath {
    let path = CGMutablePath()
    path.addRects(rects)
    return path
  }

  private static func covers(_ rect: CGRect, _ bounds: CGRect) -> Bool {
    let tolerance = ScreenRect.exactGrid
    return rect.minX <= bounds.minX + tolerance && rect.minY <= bounds.minY + tolerance
      && rect.maxX >= bounds.maxX - tolerance && rect.maxY >= bounds.maxY - tolerance
  }
}
