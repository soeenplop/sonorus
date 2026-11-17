import AppKit
import QuartzCore

/// Stepless compositor blur via the UNDOCUMENTED `CABackdropLayer` with a
/// `gaussianBlur` `CAFilter` (PLAN 6.2a: private API allowed for the blur,
/// checked at runtime, `NSVisualEffectView` as fallback). Every private
/// property is checked before use so a missing selector never raises.
@MainActor
enum BackdropBlur {
  static let radiusKeyPath = "filters.gaussianBlur.inputRadius"

  /// nil leaves `disablesOccludedBackdropBlurs` at its system default.
  static func makeLayer(disablesOccludedBlurs: Bool? = nil) -> CALayer? {
    guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
      let filter = makeFilter()
    else { return nil }
    let layer = layerType.init()
    guard responds(layer, to: "windowServerAware"), responds(layer, to: "scale") else {
      return nil
    }
    // Samples what the WindowServer composites behind this window, including
    // other apps, like behind-window blending.
    layer.setValue(true, forKey: "windowServerAware")
    layer.setValue(1.0, forKey: "scale")
    layer.filters = [filter]
    if let disablesOccludedBlurs, responds(layer, to: "disablesOccludedBackdropBlurs") {
      layer.setValue(disablesOccludedBlurs, forKey: "disablesOccludedBackdropBlurs")
    }
    setRadius(0, on: layer)
    return layer
  }

  static func setRadius(_ radius: Double, on layer: CALayer) {
    layer.setValue(max(0, radius), forKeyPath: radiusKeyPath)
  }

  private static func makeFilter() -> NSObject? {
    guard let filterType = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    let selector = NSSelectorFromString("filterWithType:")
    guard filterType.responds(to: selector),
      let filter = filterType.perform(selector, with: "gaussianBlur")?.takeUnretainedValue()
        as? NSObject,
      responds(filter, to: "name")
    else { return nil }
    filter.setValue("gaussianBlur", forKey: "name")
    filter.setValue(0, forKey: "inputRadius")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    return filter
  }

  private static func responds(_ object: NSObject, to key: String) -> Bool {
    let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
    return object.responds(to: NSSelectorFromString(setter))
  }
}

/// Content of one effect panel: the blur (backdrop layer or fallback
/// material) below a black dim layer, both masked by the same path.
@MainActor
final class EffectContentView: NSView {
  enum Blur {
    case backdrop(CALayer)
    case material(NSVisualEffectView)
  }

  static let blurAnimationKey = "sonorus.blur"
  static let dimAnimationKey = "sonorus.dim"
  /// Points over which the effect fades out at mask edges. A hard edge next
  /// to a sharp, partly covered exception looked cut out (user test).
  static let edgeFeather: CGFloat = 10

  let blur: Blur
  let dimLayer = CALayer()
  let blurMask = CALayer()
  let dimMask = CALayer()
  private let blurView: NSView

  init(frame: CGRect, blur: Blur) {
    self.blur = blur
    switch blur {
    case .backdrop(let layer):
      let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
      host.layer = layer
      host.wantsLayer = true
      blurView = host
    case .material(let view):
      view.frame = CGRect(origin: .zero, size: frame.size)
      blurView = view
    }
    super.init(frame: frame)
    wantsLayer = true
    let dimView = NSView(frame: bounds)
    dimView.layer = dimLayer
    dimView.wantsLayer = true
    dimLayer.backgroundColor = NSColor.black.cgColor
    for view in [blurView, dimView] {
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    for mask in [blurMask, dimMask] {
      // A low-resolution feathered image, scaled up smoothly.
      mask.contentsGravity = .resize
      mask.magnificationFilter = .linear
    }
    applyModel(.zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  static func makeMaterialView() -> NSVisualEffectView {
    let view = NSVisualEffectView()
    // Behind-window blending samples other apps; `active` is required because
    // the panel never becomes key.
    view.blendingMode = .behindWindow
    view.material = .hudWindow
    view.state = .active
    view.wantsLayer = true
    return view
  }

  var blurLayer: CALayer? {
    switch blur {
    case .backdrop(let layer): layer
    case .material(let view): view.layer
    }
  }

  override func layout() {
    super.layout()
    withoutActions {
      blurMask.frame = blurView.bounds
      dimMask.frame = dimLayer.bounds
    }
  }

  func setMask(_ mask: SurfaceMask) {
    withoutActions {
      switch mask {
      case .full:
        blurLayer?.mask = nil
        dimLayer.mask = nil
      case .rects(let rects):
        let image = FeatheredMask.image(
          rects: rects, size: blurView.bounds.size, feather: Self.edgeFeather)
        blurMask.contents = image
        dimMask.contents = image
        blurMask.frame = blurView.bounds
        dimMask.frame = dimLayer.bounds
        blurLayer?.mask = blurMask
        dimLayer.mask = dimMask
      }
    }
  }

  func setValues(_ values: SurfaceValues) {
    withoutActions {
      blurLayer?.removeAnimation(forKey: Self.blurAnimationKey)
      dimLayer.removeAnimation(forKey: Self.dimAnimationKey)
      applyModel(values)
    }
  }

  func animate(_ animation: SurfaceAnimation) {
    let keyTimes = animation.keyTimes.map { NSNumber(value: $0) }
    let blurAnimation: CAKeyframeAnimation
    switch blur {
    case .backdrop:
      blurAnimation = CAKeyframeAnimation(keyPath: BackdropBlur.radiusKeyPath)
      blurAnimation.values = animation.frames.map { NSNumber(value: $0.radius) }
    case .material:
      blurAnimation = CAKeyframeAnimation(keyPath: "opacity")
      blurAnimation.values = animation.frames.map { NSNumber(value: $0.blurOpacity) }
    }
    let dimAnimation = CAKeyframeAnimation(keyPath: "opacity")
    dimAnimation.values = animation.frames.map { NSNumber(value: $0.dim) }
    for keyframes in [blurAnimation, dimAnimation] {
      keyframes.keyTimes = keyTimes
      keyframes.duration = animation.duration
      keyframes.calculationMode = .linear
    }
    withoutActions {
      applyModel(animation.final)
      blurLayer?.add(blurAnimation, forKey: Self.blurAnimationKey)
      dimLayer.add(dimAnimation, forKey: Self.dimAnimationKey)
    }
  }

  private func applyModel(_ values: SurfaceValues) {
    switch blur {
    case .backdrop(let layer): BackdropBlur.setRadius(values.radius, on: layer)
    case .material(let view): view.alphaValue = values.blurOpacity
    }
    dimLayer.opacity = Float(values.dim)
  }

  private func withoutActions(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
  }
}
