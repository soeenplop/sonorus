import Foundation

/// Mask-free focus switch with two full-display surfaces: the incoming one
/// below the new anchor, the outgoing one still below the old anchor.
/// Stacked Gaussian blurs compose in quadrature and stacked layers multiply
/// their transmission, so these curves keep everything behind both surfaces
/// at exactly the target values while only the windows between them (the old
/// focus and anything raised with it) blur and dim in from zero.
enum CrossBlur {
  static let sampleCount = 24

  /// Smoothstep easing of linear time progress, clamped to 0...1.
  static func eased(_ t: Double) -> Double {
    guard t.isFinite else { return 1 }
    let t = min(1, max(0, t))
    return t * t * (3 - 2 * t)
  }

  /// Eased progress at evenly spaced key times, from 0 to 1 inclusive.
  static func samples(_ count: Int = sampleCount) -> [Double] {
    let steps = max(2, count)
    return (0..<steps).map { eased(Double($0) / Double(steps - 1)) }
  }

  static func incoming(_ target: SurfaceValues, progress p: Double) -> SurfaceValues {
    let p = min(1, max(0, p))
    return SurfaceValues(
      radius: target.radius * sqrt(p), dim: target.dim * p,
      blurOpacity: target.blurOpacity * p)
  }

  static func outgoing(_ target: SurfaceValues, progress p: Double) -> SurfaceValues {
    let p = min(1, max(0, p))
    return SurfaceValues(
      radius: target.radius * sqrt(1 - p),
      dim: remainingCover(total: target.dim, incoming: target.dim * p),
      blurOpacity: remainingCover(total: target.blurOpacity, incoming: target.blurOpacity * p))
  }

  /// Solves (1 − incoming)(1 − outgoing) = 1 − total for the outgoing cover.
  static func remainingCover(total: Double, incoming: Double) -> Double {
    guard incoming < 1 else { return 0 }
    return max(0, 1 - (1 - total) / (1 - incoming))
  }
}

/// Keyframes for one surface; the model ends at `final`, so removing the
/// finished animation never jumps.
struct SurfaceAnimation: Equatable, Sendable {
  let frames: [SurfaceValues]
  let duration: Double

  var final: SurfaceValues { frames.last ?? .zero }

  /// Key times matching `frames`, evenly spaced from 0 to 1.
  var keyTimes: [Double] {
    let last = Double(max(1, frames.count - 1))
    return frames.indices.map { Double($0) / last }
  }

  init(duration: Double, values: (Double) -> SurfaceValues) {
    self.duration = duration
    frames = CrossBlur.samples().map(values)
  }

  static func crossIn(to target: SurfaceValues, duration: Double) -> SurfaceAnimation {
    SurfaceAnimation(duration: duration) { CrossBlur.incoming(target, progress: $0) }
  }

  static func crossOut(from target: SurfaceValues, duration: Double) -> SurfaceAnimation {
    SurfaceAnimation(duration: duration) { CrossBlur.outgoing(target, progress: $0) }
  }

  static func fade(from start: SurfaceValues, to end: SurfaceValues, duration: Double)
    -> SurfaceAnimation
  {
    SurfaceAnimation(duration: duration) { start.interpolated(to: end, progress: $0) }
  }
}
