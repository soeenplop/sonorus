import AppKit
import QuartzCore

/// Mask-free focus transition with two full-display backdrop panels: the
/// incoming one sits below the new focus, the outgoing one still below the
/// old focus. Stacked Gaussian blurs compose in quadrature and stacked dims
/// multiply their transmission, so these curves keep everything behind both
/// panels at exactly `radius`/`dim` while only the windows between them (the
/// old focus and anything ⌘Tab raised) blur and dim in from zero.
public enum CrossBlur {
  public static func incomingRadius(_ radius: CGFloat, progress p: Double) -> CGFloat {
    radius * CGFloat(sqrt(min(1, max(0, p))))
  }

  public static func outgoingRadius(_ radius: CGFloat, progress p: Double) -> CGFloat {
    radius * CGFloat(sqrt(1 - min(1, max(0, p))))
  }

  public static func incomingDim(_ dim: CGFloat, progress p: Double) -> CGFloat {
    dim * CGFloat(min(1, max(0, p)))
  }

  /// Solves (1 − incoming)(1 − outgoing) = 1 − dim.
  public static func outgoingDim(_ dim: CGFloat, progress p: Double) -> CGFloat {
    let incoming = incomingDim(dim, progress: p)
    guard incoming < 1 else { return 0 }
    return max(0, 1 - (1 - dim) / (1 - incoming))
  }

  /// Eased progress samples for keyframe animations, from 0 to 1 inclusive.
  public static func samples(_ count: Int) -> [Double] {
    let steps = max(2, count)
    return (0..<steps).map {
      FocusTransition.progress(elapsed: Double($0), duration: Double(steps - 1))
    }
  }
}

/// One click-through, full-display panel: a private backdrop blur plus a
/// black dim layer, no masks. The render server runs the animations.
@MainActor
public final class BackdropPanel {
  public let panel: OverlayPanel
  public let display: DisplayInfo
  private let backdrop: CALayer
  private let dim = CALayer()
  public private(set) var radius: CGFloat = 0
  public private(set) var dimAlpha: CGFloat = 0

  public init?(display: DisplayInfo, disablesOccludedBlurs: Bool) {
    guard let backdrop = BackdropBlur.makeLayer(radius: 0) else { return nil }
    self.display = display
    self.backdrop = backdrop
    panel = OverlayPanel(appKitFrame: display.appKitFrame, level: .normal)
    let root = NSView(frame: CGRect(origin: .zero, size: display.appKitFrame.size))
    root.layer = CALayer()
    root.wantsLayer = true
    for layer in [backdrop, dim] {
      layer.frame = root.bounds
      layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      root.layer?.addSublayer(layer)
    }
    dim.backgroundColor = NSColor.black.cgColor
    dim.opacity = 0
    let setter = NSSelectorFromString("setDisablesOccludedBackdropBlurs:")
    if backdrop.responds(to: setter) {
      backdrop.setValue(disablesOccludedBlurs, forKey: "disablesOccludedBackdropBlurs")
    }
    panel.contentView = root
  }

  /// Immediate values; removes running animations.
  public func set(radius: CGFloat, dim alpha: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdrop.removeAllAnimations()
    dim.removeAllAnimations()
    BackdropBlur.setRadius(radius, on: backdrop)
    dim.opacity = Float(alpha)
    CATransaction.commit()
    self.radius = radius
    dimAlpha = alpha
  }

  /// Keyframe animation computed by `values(progress)`; the model ends at the
  /// last value, so nothing jumps when the animation is removed.
  public func animate(
    duration: Double, samples: [Double], values: (Double) -> (radius: CGFloat, dim: CGFloat)
  ) {
    let frames = samples.map(values)
    guard let last = frames.last else { return }
    let times = (0..<frames.count).map { NSNumber(value: Double($0) / Double(frames.count - 1)) }
    let blur = CAKeyframeAnimation(keyPath: "filters.gaussianBlur.inputRadius")
    blur.values = frames.map { NSNumber(value: Double($0.radius)) }
    blur.keyTimes = times
    blur.duration = duration
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = frames.map { NSNumber(value: Double($0.dim)) }
    fade.keyTimes = times
    fade.duration = duration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    BackdropBlur.setRadius(last.radius, on: backdrop)
    dim.opacity = Float(last.dim)
    backdrop.add(blur, forKey: "crossBlur")
    dim.add(fade, forKey: "crossDim")
    CATransaction.commit()
    radius = last.radius
    dimAlpha = last.dim
  }
}
