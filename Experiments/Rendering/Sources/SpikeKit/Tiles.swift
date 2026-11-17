import AppKit

/// Flipped root view so tile frames can use top-left display coordinates.
public final class FlippedView: NSView {
  override public var isFlipped: Bool { true }
}

/// Pooled effect + dim views placed on exact rectangles: no mask image, only
/// frame changes, which keeps updates in the low milliseconds.
@MainActor
public final class TileSurface {
  public let display: DisplayInfo
  public let root: NSView
  public var material: NSVisualEffectView.Material
  public var alpha: CGFloat
  public let dimAlpha: CGFloat
  public private(set) var effects: [NSVisualEffectView] = []
  private var dims: [NSView] = []

  public init(
    display: DisplayInfo, root: NSView, material: NSVisualEffectView.Material, alpha: CGFloat,
    dimAlpha: CGFloat
  ) {
    self.display = display
    self.root = root
    self.material = material
    self.alpha = alpha
    self.dimAlpha = dimAlpha
  }

  /// Returns the number of visible tiles on this display.
  @discardableResult
  public func layout(quartzRects: [CGRect]) -> Int {
    let bounds = display.quartzBounds
    let local = quartzRects.map { $0.intersection(bounds) }
      .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
      .map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
    while effects.count < local.count {
      let effect = EffectFactory.effectView(material: material, alpha: alpha)
      effect.autoresizingMask = []
      root.addSubview(effect)
      effects.append(effect)
      // Tiles never overlap, so the dim only has to sit above its own effect.
      let dim = NSView()
      dim.wantsLayer = true
      dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
      root.addSubview(dim)
      dims.append(dim)
    }
    for index in effects.indices {
      let visible = index < local.count
      effects[index].isHidden = !visible
      dims[index].isHidden = !visible || dimAlpha == 0
      if visible {
        effects[index].frame = local[index]
        dims[index].frame = local[index]
      }
    }
    return local.count
  }
}
