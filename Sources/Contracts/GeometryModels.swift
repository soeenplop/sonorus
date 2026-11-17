import Foundation

/// Global screen coordinates use points, the primary display's top-left origin,
/// x increasing rightward and y increasing downward (Quartz convention).
/// AppKit adapters convert at their boundary; negative coordinates are valid.
public struct ScreenPoint: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct ScreenRect: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isUsable: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && width > 0 && height > 0
  }
}

/// Coordinates relative to one display, normally within 0...1. Validation and
/// clipping belong to Geometry; these values are never interpreted as pixels.
public struct NormalizedRect: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
