import AppKit
import QuartzCore

/// Stepless compositor blur via the UNDOCUMENTED `CABackdropLayer` with a
/// `gaussianBlur` `CAFilter` (the building block behind NSVisualEffectView).
/// Unlike the WindowServer window radius it is an ordinary layer: masks,
/// rounded paths and per-region radii apply. User decision (17.11.2026):
/// private API allowed for the blur, native NSVisualEffectView as fallback.
@MainActor
public enum BackdropBlur {
  public static var isAvailable: Bool {
    NSClassFromString("CABackdropLayer") is CALayer.Type
      && NSClassFromString("CAFilter") is NSObject.Type
  }

  static func makeLayer(radius: CGFloat) -> CALayer? {
    guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
      let filter = makeFilter(radius: radius)
    else { return nil }
    let layer = layerType.init()
    // Samples what the WindowServer composites behind this window, including
    // other apps, like behind-window blending.
    layer.setValue(true, forKey: "windowServerAware")
    layer.setValue(1.0, forKey: "scale")
    layer.filters = [filter]
    return layer
  }

  private static func makeFilter(radius: CGFloat) -> NSObject? {
    guard let filterType = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    let selector = NSSelectorFromString("filterWithType:")
    guard filterType.responds(to: selector),
      let filter = filterType.perform(selector, with: "gaussianBlur")?.takeUnretainedValue()
        as? NSObject
    else { return nil }
    filter.setValue("gaussianBlur", forKey: "name")
    filter.setValue(radius, forKey: "inputRadius")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    return filter
  }

  static func setRadius(_ radius: CGFloat, on layer: CALayer) {
    layer.setValue(max(0, radius), forKeyPath: "filters.gaussianBlur.inputRadius")
  }
}

/// Layer-hosting view around one backdrop blur layer.
@MainActor
public final class BackdropView: NSView {
  public private(set) var radius: CGFloat

  public init?(frame: CGRect, radius: CGFloat) {
    guard let backdrop = BackdropBlur.makeLayer(radius: radius) else { return nil }
    self.radius = radius
    super.init(frame: frame)
    layer = backdrop
    wantsLayer = true
    autoresizingMask = [.width, .height]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public func setRadius(_ radius: CGFloat) {
    guard radius != self.radius, let layer else { return }
    self.radius = radius
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    BackdropBlur.setRadius(radius, on: layer)
    CATransaction.commit()
  }
}
