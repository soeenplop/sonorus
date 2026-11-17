import AppKit

/// Display-local, disjoint alpha fields. Newly protected pixels disappear
/// immediately; only newly exposed pixels ease into the unchanged material.
public struct FocusTransition {
  public struct Region {
    public let path: CGPath
    public let initialOpacity: Double
  }
  public static func duration(_ requested: Double) -> Double {
    requested.isFinite ? min(1.5, max(0, requested)) : 0.75
  }
  public static func progress(elapsed: Double, duration: Double) -> Double {
    guard duration > 0 else { return 1 }
    let t = min(1, max(0, elapsed / duration))
    return t * t * (3 - 2 * t)
  }
  public private(set) var target: CGPath?
  public private(set) var regions: [Region] = []
  public private(set) var started = 0.0
  public private(set) var generation = 0
  public let duration: Double
  /// Bounds view/mask allocations even under sustained adversarial switching.
  public static let maximumRegions = 16

  public init(duration: Double) { self.duration = Self.duration(duration) }
  public func opacity(_ region: Region, at time: Double) -> Double {
    region.initialOpacity + (1 - region.initialOpacity)
      * Self.progress(elapsed: time - started, duration: duration)
  }
  public var base: CGPath {
    regions.reduce(target ?? CGMutablePath()) { $0.subtracting($1.path) }
  }
  /// Retarget from the sampled presentation state, never an obsolete endpoint.
  /// Existing regions retain their opacity and are clipped to the latest target.
  public mutating func retarget(
    _ next: CGPath, at time: Double, animate: Bool, outgoing: CGPath? = nil,
    retirementClip: CGPath? = nil
  ) {
    var nextRegions: [Region] = []
    let allowed = retirementClip.map { next.intersection($0) } ?? next
    if duration > 0, let previous = target {
      for region in regions {
        let clipped = region.path.intersection(allowed)
        let alpha = opacity(region, at: time)
        if !clipped.isEmpty && alpha < 1 {
          nextRegions.append(Region(path: clipped, initialOpacity: alpha))
        }
      }
      var exposed = (outgoing ?? next.subtracting(previous)).intersection(allowed)
      // Explicit outgoing geometry can overlap an unfinished retirement after
      // rapid switches between overlapping windows. Keep its sampled opacity
      // rather than stacking a second native blur fragment over it.
      for retained in nextRegions { exposed = exposed.subtracting(retained.path) }
      if animate && !exposed.isEmpty {
        nextRegions.append(Region(path: exposed, initialOpacity: 0))
      }
    }
    // At the cap only the oldest retiring fragments finish immediately; the
    // current focus remains protected and the most recent transition wins.
    regions = Array(nextRegions.suffix(Self.maximumRegions))
    target = next
    started = time
    generation += 1
  }
  /// Cropped bounding boxes may overlap although effect paths do not. Bound
  /// total bitmap area as well as view count; finish oldest fragments first.
  public mutating func limitRasterArea(to budget: CGFloat) {
    var area: CGFloat = 0
    var kept: [Region] = []
    for region in regions.reversed() {
      let box = region.path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
      let cost = box.width * box.height
      if area + cost <= budget {
        kept.append(region)
        area += cost
      }
    }
    regions = kept.reversed()
  }
  /// Start the duration after mask preparation, which can exceed a frame on
  /// high-resolution displays. CPU raster time must not consume the animation.
  public mutating func begin(at time: Double) { started = time }
  public mutating func finish() { regions.removeAll() }
  public mutating func cancel() {
    target = nil
    regions.removeAll()
    generation += 1
  }
}

/// One panel, one static base and cropped, non-overlapping native effect views.
/// Rasterize only on retarget/end; 30 Hz ticks change local view opacity only.
@MainActor
public final class FocusTransitionSurface {
  public let surface: MaskedEffectSurface
  public private(set) var planner: FocusTransition
  private var fragments: [MaskedEffectSurface] = []
  private var timer: Timer?
  private var material: NSVisualEffectView.Material
  private var alpha: CGFloat
  private var dimAlpha: CGFloat
  private let fade: MenuFade
  private let native: Bool
  private var guarding = false
  /// Points of `BackdropBlur` radius, or nil for the native effect. With a
  /// backdrop, retiring regions ramp their blur radius (and dim) instead of
  /// cross-fading a fully blurred fragment.
  public private(set) var backdropRadius: CGFloat?

  public init(
    surface: MaskedEffectSurface, duration: Double, material: NSVisualEffectView.Material,
    alpha: CGFloat, dimAlpha: CGFloat, fade: MenuFade, native: Bool
  ) {
    self.surface = surface
    planner = FocusTransition(duration: duration)
    self.material = material
    self.alpha = alpha
    self.dimAlpha = dimAlpha
    self.fade = fade
    self.native = native
  }

  private var now: Double { ProcessInfo.processInfo.systemUptime }
  private func log(_ event: String) {
    Log.info(
      "transition displayID=\(surface.display.displayID) generation=\(planner.generation) \(event)")
  }
  /// Live tuning; running fragments keep their own fade opacity.
  public func setAppearance(
    material: NSVisualEffectView.Material, alpha: CGFloat, dimAlpha: CGFloat
  ) {
    self.material = material
    self.alpha = alpha
    self.dimAlpha = dimAlpha
    for target in [surface] + fragments {
      target.setAppearance(material: material, alpha: alpha, dimAlpha: dimAlpha)
    }
  }
  /// Switches the base and future fragments to the backdrop blur.
  @discardableResult
  public func useBackdrop(radius: CGFloat) -> Bool {
    guard surface.useBackdrop(radius: radius) else { return false }
    backdropRadius = radius
    return true
  }
  /// Live radius tuning; running fragments keep their ramp progress.
  public func setBackdropRadius(_ radius: CGFloat) {
    guard backdropRadius != nil else { return }
    backdropRadius = radius
    surface.backdrop?.setRadius(radius)
    if timer != nil { step() }
  }
  public func cancel(reason: String) {
    if !planner.regions.isEmpty { log("cancel reason=\(reason)") }
    timer?.invalidate()
    timer = nil
    for fragment in fragments { fragment.host.removeFromSuperview() }
    fragments.removeAll()
    planner.cancel()
  }
  /// A reorder guard never changes transition history. Fragments that could
  /// cover the newly protected area are hidden; the others keep their sampled
  /// opacity, so rapid switches do not jump between sharp and fully blurred.
  public func guardPlacement(_ path: CGPath) {
    guarding = true
    var base = path
    for (region, fragment) in zip(planner.regions, fragments) {
      let safe = region.path.subtracting(path).isEmpty
      fragment.host.isHidden = !safe
      if safe { base = base.subtracting(region.path) }
    }
    if native {
      surface.applyNative(path: base, fade: fade)
    } else {
      surface.apply(path: base, maskOnHost: false)
    }
    surface.displayNow()
  }
  public func retarget(
    _ path: CGPath, animate: Bool, outgoing: CGPath? = nil, retirementClip: CGPath? = nil
  ) {
    if planner.target == path && outgoing == nil {
      if guarding {
        rebuild()
        guarding = false
      }
      return
    }
    guarding = false
    // Geometry updates and placement fallback are immediate. They cannot
    // keep sampled retirement holes alive while a window is being dragged.
    if !animate && outgoing == nil { planner.finish() }
    if !planner.regions.isEmpty { log("cancel reason=retarget") }
    timer?.invalidate()
    let time = now
    planner.retarget(
      path, at: time, animate: animate, outgoing: outgoing, retirementClip: retirementClip)
    let bounds = surface.host.bounds
    planner.limitRasterArea(to: 2 * (bounds.width + 2) * (bounds.height + 2))
    rebuild()
    planner.begin(at: now)
    guard !planner.regions.isEmpty else { return }
    log("start duration=\(planner.duration) regions=\(planner.regions.count)")
    let rate = backdropRadius == nil ? 30.0 : 60.0
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
  }
  private func installBase() {
    if native {
      surface.applyNative(path: planner.base, fade: fade)
    } else {
      // Retiring fragments are siblings of the base effect. A host mask
      // would clip them out along with the base, preventing their fade-in.
      surface.apply(path: planner.base, maskOnHost: false)
    }
  }
  private func rebuild() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for fragment in fragments { fragment.host.removeFromSuperview() }
    fragments.removeAll()
    installBase()
    for region in planner.regions {
      let scale = surface.display.scale
      let box = region.path.boundingBoxOfPath
      // A backdrop blur samples only inside its layer. Without a margin the
      // retiring window keeps a crisp outline and dissolves into its
      // surroundings only when the base takes over at the end.
      let margin = (backdropRadius ?? 0) * 2
      let wide = box.insetBy(dx: -margin, dy: -margin)
      let crop = CGRect(
        x: floor(wide.minX * scale) / scale, y: floor(wide.minY * scale) / scale,
        width: ceil(wide.maxX * scale) / scale - floor(wide.minX * scale) / scale,
        height: ceil(wide.maxY * scale) / scale - floor(wide.minY * scale) / scale)
      let fragment = MaskedEffectSurface(
        display: surface.display, material: material, alpha: alpha, dimAlpha: dimAlpha,
        size: crop.size)
      fragment.host.frame = crop
      if let backdropRadius {
        fragment.useBackdrop(radius: backdropRadius * region.initialOpacity)
      }
      if native {
        // Native masks on cropped regions preserve the exact global geometry and
        // menu envelope. No full-display mask is generated on animation ticks.
        fragment.applyNativeImage(
          NativeEffectMask.image(path: region.path, fade: fade, scale: scale, crop: crop))
      } else {
        // Vector mask in fragment coordinates; the render server rasterizes
        // it, so switches need no CPU bitmap at all.
        var shift = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        fragment.apply(
          path: region.path.copy(using: &shift) ?? region.path, maskOnHost: false)
      }
      Self.show(fragment, opacity: region.initialOpacity, radius: backdropRadius)
      surface.host.addSubview(fragment.host)
      fragments.append(fragment)
    }
    // Base mask and fragments must reach the screen in the same frame.
    surface.displayNow()
    CATransaction.commit()
  }
  /// Native fragments cross-fade; backdrop fragments ramp radius and dim.
  private static func show(_ fragment: MaskedEffectSurface, opacity: Double, radius: CGFloat?) {
    guard let radius, let backdrop = fragment.backdrop else {
      fragment.host.alphaValue = opacity
      return
    }
    fragment.host.alphaValue = 1
    backdrop.setRadius(radius * opacity)
    fragment.dim.alphaValue = opacity
  }
  private func step() {
    let time = now
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (region, fragment) in zip(planner.regions, fragments) {
      Self.show(fragment, opacity: planner.opacity(region, at: time), radius: backdropRadius)
    }
    if FocusTransition.progress(elapsed: time - planner.started, duration: planner.duration) == 1 {
      log("end")
      timer?.invalidate()
      timer = nil
      planner.finish()
      if !guarding { rebuild() }
    }
    CATransaction.commit()
  }
}
