import AppKit
import QuartzCore

/// Vector masks for `--mask layer`: a CAShapeLayer path instead of a mask
/// image, so updates need no CPU rasterisation (the render server rasterises
/// the path). Paths are in display-local view coordinates.
public enum MaskPath {
  /// Painter's algorithm with boolean path operations (`CGPath.union`,
  /// `CGPath.subtracting`, macOS 13+): inactive windows add their rounded
  /// rectangle, sharp windows punch theirs out, back to front.
  /// https://developer.apple.com/documentation/coregraphics/cgpath/union(_:using:)
  public static func painter(
    pieces backToFront: [MaskPiece], screen: CGRect, cornerRadius: CGFloat, flipped: Bool
  ) -> CGPath {
    var path: CGPath = CGMutablePath()
    var hasFill = false
    for piece in backToFront {
      guard piece.rect.intersects(screen) else { continue }
      if piece.kind == .punch && !hasFill { continue }
      let shape = roundedRect(local(piece.rect, screen: screen, flipped: flipped), cornerRadius)
      switch piece.kind {
      case .effect:
        path = hasFill ? path.union(shape) : shape
        hasFill = true
      case .punch:
        path = path.subtracting(shape)
      }
    }
    return path
  }

  /// Exact, non-overlapping visible rectangles in one path. Shared edges of
  /// adjacent rectangles are filled in a single pass, so they cannot leave
  /// antialiasing seams the way separate tile views can.
  public static func rects(_ rects: [CGRect], screen: CGRect, flipped: Bool) -> CGPath {
    let path = CGMutablePath()
    for rect in rects where rect.intersects(screen) {
      path.addRect(local(rect.intersection(screen), screen: screen, flipped: flipped))
    }
    return path
  }

  /// Global Quartz (top-left, y down) → display-local view coordinates.
  public static func local(_ rect: CGRect, screen: CGRect, flipped: Bool) -> CGRect {
    let x = rect.minX - screen.minX
    let top = rect.minY - screen.minY
    return CGRect(
      x: x, y: flipped ? top : screen.height - top - rect.height, width: rect.width,
      height: rect.height)
  }

  public static func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    // CGPath(roundedRect:) traps when the radius exceeds half a side.
    let clamped = max(0, min(radius, rect.width / 2, rect.height / 2))
    return CGPath(roundedRect: rect, cornerWidth: clamped, cornerHeight: clamped, transform: nil)
  }
}

/// One continuous effect view plus dimming (full display or a scope), each masked by a CAShapeLayer
/// with the same path. Used as the panel's (non-flipped) content view, so the
/// layer coordinates are bottom-left like the view's.
@MainActor
public final class MaskedEffectSurface {
  public let display: DisplayInfo
  public let host: NSView
  public let effect: NSVisualEffectView
  public let dim: NSView
  public let effectMask = CAShapeLayer()
  public let dimMask = CAShapeLayer()
  /// Optional private compositor blur replacing `effect`; see `useBackdrop`.
  public private(set) var backdrop: BackdropView?
  private let backdropMask = CAShapeLayer()
  /// `effect`: mask on the NSVisualEffectView's own layer. `host`: mask on the
  /// container (affects effect and dim together). Which one keeps the
  /// behind-window blur intact is a manual check.
  public let maskOnHost: Bool

  public init(
    display: DisplayInfo, material: NSVisualEffectView.Material, alpha: CGFloat,
    dimAlpha: CGFloat, maskOnHost: Bool = false, size: CGSize? = nil, menuFade: CGFloat = 0,
    menuTopInset: CGFloat = 0, menuFadeWithinBar: Bool = false
  ) {
    self.display = display
    self.maskOnHost = maskOnHost
    let bounds = CGRect(origin: .zero, size: size ?? display.appKitFrame.size)
    host = NSView(frame: bounds)
    host.wantsLayer = true
    effect = EffectFactory.effectView(material: material, alpha: alpha)
    effect.frame = bounds
    effect.wantsLayer = true
    host.addSubview(effect)
    dim = NSView(frame: bounds)
    dim.autoresizingMask = [.width, .height]
    dim.wantsLayer = true
    dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
    dim.isHidden = dimAlpha == 0
    host.addSubview(dim)
    for mask in [effectMask, dimMask] {
      mask.frame = bounds
      mask.fillColor = NSColor.white.cgColor
      mask.path = CGMutablePath()
    }
    let fade =
      menuFadeWithinBar
      ? MenuFade.insideMenuBar(bounds: bounds, menuInset: display.menuBarInset, points: menuFade)
      : MenuFade(
        bounds: bounds, menuInset: display.menuBarInset, points: menuFade, topInset: menuTopInset)
    if fade.height > 0 {
      effectMask.mask = Self.gradient(fade)
      dimMask.mask = Self.gradient(fade)
    }
    if maskOnHost {
      host.layer?.mask = effectMask
    } else {
      effect.layer?.mask = effectMask
      dim.layer?.mask = dimMask
    }
  }

  /// Whether the mask is still attached where it was installed (AppKit owns
  /// the view layers and could replace them).
  public var isMaskAttached: Bool {
    maskOnHost
      ? host.layer?.mask === effectMask
      : effect.layer?.mask === effectMask && dim.layer?.mask === dimMask
  }

  /// Use the public NSVisualEffectView mask API instead of masking its backing
  /// layer. Both geometry and fade are rasterized together, once per display;
  /// this is an alternative compositor path, not proof of an OS layer-mask bug.
  public func applyNative(path: CGPath, fade: MenuFade) {
    let image = NativeEffectMask.image(path: path, fade: fade, scale: display.scale)
    applyNativeImage(image)
  }

  public func applyNativeImage(_ image: NSImage) {
    host.layer?.mask = nil
    effect.layer?.mask = nil
    effect.maskImage = image
    let mask = CALayer()
    mask.frame = dim.bounds
    mask.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    dim.layer?.mask = mask
  }

  /// Replaces the native effect with a `BackdropView` of `radius` points that
  /// shares the effect mask path. Returns false when the private classes are
  /// missing, leaving the native effect in place.
  @discardableResult
  public func useBackdrop(radius: CGFloat) -> Bool {
    guard backdrop == nil else { return true }
    guard let view = BackdropView(frame: host.bounds, radius: radius) else { return false }
    backdropMask.frame = host.bounds
    backdropMask.fillColor = NSColor.white.cgColor
    backdropMask.path = effectMask.path
    // A layer can mask only one layer: copy the menu fade gradient.
    if let fade = effectMask.mask as? CAGradientLayer {
      let copy = CAGradientLayer()
      copy.frame = fade.frame
      copy.colors = fade.colors
      copy.startPoint = fade.startPoint
      copy.endPoint = fade.endPoint
      backdropMask.mask = copy
    }
    host.addSubview(view, positioned: .below, relativeTo: dim)
    effect.isHidden = true
    if !maskOnHost { view.layer?.mask = backdropMask }
    backdrop = view
    return true
  }

  /// Live tuning without touching masks or window order.
  public func setAppearance(
    material: NSVisualEffectView.Material, alpha: CGFloat, dimAlpha: CGFloat
  ) {
    effect.material = material
    effect.alphaValue = alpha
    dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
    dim.isHidden = dimAlpha == 0
  }

  /// NSVisualEffectView consumes `maskImage` in its next display pass, while
  /// window ordering takes effect immediately. Display now, so a following
  /// reorder or fragment removal never shows the previous mask for a frame.
  public func displayNow() {
    host.window?.layoutIfNeeded()
    host.window?.displayIfNeeded()
  }

  public static func gradient(_ fade: MenuFade) -> CAGradientLayer {
    let layer = CAGradientLayer()
    layer.frame = fade.bounds
    layer.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
    layer.startPoint = fade.startPoint
    layer.endPoint = fade.endPoint
    return layer
  }

  /// nil fills the scope; the independent alpha envelope stays attached.
  public func apply(path: CGPath?, maskOnHost useHost: Bool? = nil) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    effect.maskImage = nil
    if path == nil && effectMask.mask == nil {
      host.layer?.mask = nil
      effect.layer?.mask = nil
      dim.layer?.mask = nil
      backdrop?.layer?.mask = nil
      CATransaction.commit()
      return
    }
    let fill = path ?? CGPath(rect: host.bounds, transform: nil)
    effectMask.path = fill
    dimMask.path = fill
    backdropMask.path = fill
    if useHost ?? maskOnHost {
      host.layer?.mask = effectMask
      backdrop?.layer?.mask = nil
    } else {
      host.layer?.mask = nil
      effect.layer?.mask = effectMask
      dim.layer?.mask = dimMask
      backdrop?.layer?.mask = backdropMask
    }
    CATransaction.commit()
  }
}

/// Single alpha field shared by native blur and dim. Coordinates are local,
/// unflipped points, explicitly rasterized at the display backing scale.
@MainActor
public enum NativeEffectMask {
  public static func image(
    path: CGPath, fade: MenuFade, scale: CGFloat = 1, crop: CGRect? = nil
  ) -> NSImage {
    let area = crop ?? fade.bounds
    let drawing = NSImage(size: area.size, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.translateBy(x: -area.minX, y: -area.minY)
      context.clear(area)
      context.addPath(path)
      context.clip()
      if fade.height == 0 {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(fade.bounds)
      } else {
        let gradient = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: [NSColor.clear.cgColor, NSColor.white.cgColor] as CFArray,
          locations: [0, 1])!
        context.drawLinearGradient(
          gradient,
          start: CGPoint(x: 0, y: fade.bounds.maxY - fade.topInset),
          end: CGPoint(x: 0, y: fade.bounds.maxY - fade.topInset - fade.height),
          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      }
      return true
    }
    let pixels = max(1, scale.isFinite ? scale : 1)
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int(ceil(area.width * pixels))),
      pixelsHigh: max(1, Int(ceil(area.height * pixels))),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = area.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawing.draw(in: CGRect(origin: .zero, size: area.size))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: area.size)
    image.addRepresentation(bitmap)
    return image
  }
}
