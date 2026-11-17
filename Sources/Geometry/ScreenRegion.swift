import Contracts

/// Area in global Quartz points represented by pairwise non-overlapping
/// rectangles. Every operation preserves that invariant, so the summed area of
/// `rectangles` equals the covered area and no point is covered twice.
public struct ScreenRegion: Equatable, Sendable {
  public private(set) var rectangles: [ScreenRect]

  public static let empty = ScreenRegion()

  public init() {
    rectangles = []
  }

  public init(_ rect: ScreenRect) {
    rectangles = rect.isUsable ? [rect] : []
  }

  /// Unions arbitrary, possibly overlapping or invalid rectangles.
  public init<S: Sequence>(unioning rects: S) where S.Element == ScreenRect {
    self.init()
    for rect in rects { formUnion(rect) }
  }

  public var isEmpty: Bool { rectangles.isEmpty }

  public var area: Double { rectangles.reduce(0) { $0 + $1.area } }

  public mutating func formUnion(_ rect: ScreenRect) {
    guard rect.isUsable else { return }
    var pieces = [rect]
    for existing in rectangles {
      pieces = pieces.flatMap { $0.subtracting(existing) }
      if pieces.isEmpty { return }
    }
    rectangles.append(contentsOf: pieces)
  }

  public mutating func formUnion(_ other: ScreenRegion) {
    for rect in other.rectangles { formUnion(rect) }
  }

  public func union(_ other: ScreenRegion) -> ScreenRegion {
    var result = self
    result.formUnion(other)
    return result
  }

  public func subtracting(_ rect: ScreenRect) -> ScreenRegion {
    guard rect.isUsable else { return self }
    return ScreenRegion(disjoint: rectangles.flatMap { $0.subtracting(rect) })
  }

  public func subtracting(_ other: ScreenRegion) -> ScreenRegion {
    other.rectangles.reduce(self) { $0.subtracting($1) }
  }

  public func intersection(_ rect: ScreenRect) -> ScreenRegion {
    ScreenRegion(disjoint: rectangles.compactMap { $0.intersection(rect) })
  }

  public func intersection(_ other: ScreenRegion) -> ScreenRegion {
    ScreenRegion(disjoint: other.rectangles.flatMap { intersection($0).rectangles })
  }

  public func intersects(_ rect: ScreenRect) -> Bool {
    rectangles.contains { $0.intersects(rect) }
  }

  public func contains(_ point: ScreenPoint) -> Bool {
    rectangles.contains {
      point.x >= $0.minX && point.x < $0.maxX && point.y >= $0.minY && point.y < $0.maxY
    }
  }

  /// Same area with fewer, deterministically ordered pieces: horizontally
  /// adjacent rectangles of equal rows and then vertically adjacent rectangles
  /// of equal columns are merged; the result is sorted by y, then x.
  public func coalesced() -> ScreenRegion {
    let rows = Self.merge(rectangles, horizontally: true)
    let pieces = Self.merge(rows, horizontally: false)
    return ScreenRegion(disjoint: pieces.sorted(by: Self.readingOrder))
  }

  private init(disjoint rects: [ScreenRect]) {
    rectangles = rects.filter(\.isUsable)
  }

  private static func readingOrder(_ lhs: ScreenRect, _ rhs: ScreenRect) -> Bool {
    (lhs.y, lhs.x, lhs.height, lhs.width) < (rhs.y, rhs.x, rhs.height, rhs.width)
  }

  /// Merges exactly abutting neighbors that share both perpendicular edges.
  private static func merge(_ rects: [ScreenRect], horizontally: Bool) -> [ScreenRect] {
    let sorted = rects.sorted { lhs, rhs in
      horizontally
        ? (lhs.y, lhs.height, lhs.x) < (rhs.y, rhs.height, rhs.x)
        : (lhs.x, lhs.width, lhs.y) < (rhs.x, rhs.width, rhs.y)
    }
    var result: [ScreenRect] = []
    for rect in sorted {
      if let last = result.last {
        if horizontally, last.y == rect.y, last.height == rect.height, last.maxX == rect.minX {
          result[result.count - 1].width = rect.maxX - last.minX
          continue
        }
        if !horizontally, last.x == rect.x, last.width == rect.width, last.maxY == rect.minY {
          result[result.count - 1].height = rect.maxY - last.minY
          continue
        }
      }
      result.append(rect)
    }
    return result
  }
}
