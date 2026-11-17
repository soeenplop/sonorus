import Contracts

/// Values one effect surface shows. `radius` drives the backdrop blur in
/// points, `blurOpacity` the fallback material, `dim` the black layer opacity.
struct SurfaceValues: Equatable, Sendable {
  var radius: Double
  var dim: Double
  var blurOpacity: Double

  static let zero = SurfaceValues(radius: 0, dim: 0, blurOpacity: 0)

  func interpolated(to other: SurfaceValues, progress p: Double) -> SurfaceValues {
    let p = min(1, max(0, p))
    return SurfaceValues(
      radius: radius + (other.radius - radius) * p, dim: dim + (other.dim - dim) * p,
      blurOpacity: blurOpacity + (other.blurOpacity - blurOpacity) * p)
  }
}

/// The single mapping from user settings to rendered values.
public struct EffectAppearance: Equatable, Sendable {
  /// Blur 1.0 maps to this backdrop radius in points.
  public static let maximumRadius = 64.0

  public let radius: Double
  public let dim: Double
  /// Opacity of the fallback material, which has no radius: the lower half
  /// of the blur range fades it in, the upper half keeps it fully opaque.
  public let fallbackOpacity: Double
  public let transitionDuration: Double

  public init(_ settings: EffectSettings) {
    radius = settings.blur * Self.maximumRadius
    dim = 1 - settings.backgroundBrightness
    fallbackOpacity = min(1, 2 * settings.blur)
    transitionDuration = settings.transitionDuration
  }

  var values: SurfaceValues {
    SurfaceValues(radius: radius, dim: dim, blurOpacity: fallbackOpacity)
  }
}
