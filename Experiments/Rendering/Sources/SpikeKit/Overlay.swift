import AppKit

/// Borderless, non-activating, click-through overlay panel.
///
/// - `ignoresMouseEvents`: https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
/// - `.nonactivatingPanel`: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
/// - Collection behavior: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct
public final class OverlayPanel: NSPanel {
  public init(appKitFrame: CGRect, level: NSWindow.Level, clickThrough: Bool = true) {
    super.init(
      contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = clickThrough
    self.level = level
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .none
    setFrame(appKitFrame, display: false)
  }

  override public var canBecomeKey: Bool { false }
  override public var canBecomeMain: Bool { false }
}

public enum Materials {
  /// Public `NSVisualEffectView.Material` values worth comparing for a focus blur.
  /// https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum
  public static let all: [(String, NSVisualEffectView.Material)] = [
    ("hudWindow", .hudWindow), ("fullScreenUI", .fullScreenUI),
    ("underWindowBackground", .underWindowBackground), ("windowBackground", .windowBackground),
    ("sidebar", .sidebar), ("menu", .menu), ("popover", .popover), ("sheet", .sheet),
    ("headerView", .headerView), ("titlebar", .titlebar), ("contentBackground", .contentBackground),
    ("toolTip", .toolTip), ("selection", .selection),
    ("underPageBackground", .underPageBackground),
  ]

  public static func named(_ name: String) -> NSVisualEffectView.Material? {
    all.first { $0.0 == name }?.1
  }
}

@MainActor
public enum EffectFactory {
  /// Behind-window blending samples what the window server composites below
  /// this window, including other apps. `state = .active` is required because
  /// the panel never becomes key.
  /// https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow
  public static func effectView(material: NSVisualEffectView.Material, alpha: CGFloat)
    -> NSVisualEffectView
  {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.state = .active
    view.material = material
    view.alphaValue = alpha
    view.autoresizingMask = [.width, .height]
    return view
  }
}

/// One rectangle of the painter's-algorithm mask in global Quartz points.
public struct MaskPiece: Sendable {
  public enum Kind: Sendable {
    case effect
    case punch
  }

  public let rect: CGRect
  public let kind: Kind

  public init(rect: CGRect, kind: Kind) {
    self.rect = rect
    self.kind = kind
  }
}

public enum MaskBuilder {
  /// Back-to-front painting: inactive windows add effect, focused windows and
  /// exceptions punch it out again. Only the parts left visible by windows in
  /// front keep the effect, which matches "visible parts of inactive windows".
  /// Only layer-0 windows are considered; higher levels sit above the overlay.
  public static func pieces(
    frontToBack windows: [CGWin], focused: CGWindowID?, exceptions: Set<CGWindowID>,
    ownPID: pid_t = getpid()
  ) -> [MaskPiece] {
    windows.reversed()
      .filter { $0.isNormalLevel && $0.pid != ownPID && $0.alpha > 0 }
      .map { window in
        let sharp = window.id == focused || exceptions.contains(window.id)
        return MaskPiece(rect: window.bounds, kind: sharp ? .punch : .effect)
      }
  }

  /// Mask image for one screen. The drawing handler is resolution independent,
  /// so the same image renders crisply on 1x and 2x displays.
  @MainActor
  public static func image(
    for pieces: [MaskPiece], screenQuartzBounds screen: CGRect, cornerRadius: CGFloat
  ) -> NSImage {
    NSImage(size: screen.size, flipped: true) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.clear(CGRect(origin: .zero, size: screen.size))
      for piece in pieces {
        let local = piece.rect.offsetBy(dx: -screen.minX, dy: -screen.minY)
        guard local.intersects(CGRect(origin: .zero, size: screen.size)) else { continue }
        context.addPath(MaskPath.roundedRect(local, cornerRadius))
        switch piece.kind {
        case .effect:
          context.setBlendMode(.normal)
          context.setFillColor(NSColor.white.cgColor)
        case .punch:
          context.setBlendMode(.clear)
        }
        context.fillPath()
      }
      return true
    }
  }

  /// Exact visible rectangles of effect windows (no rounded corners), for
  /// statistics and for choosing hit-test points.
  public static func visibleEffectRects(frontToBack windows: [CGWin], effectIDs: Set<CGWindowID>)
    -> [(CGWin, [CGRect])]
  {
    var covered: [CGRect] = []
    var result: [(CGWin, [CGRect])] = []
    for window in windows where window.isNormalLevel {
      if effectIDs.contains(window.id) {
        var visible = [window.bounds]
        for cover in covered { visible = visible.flatMap { subtract(cover, from: $0) } }
        result.append((window, visible))
      }
      covered.append(window.bounds)
    }
    return result
  }

  public static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
    let overlap = rect.intersection(cut)
    guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
    var pieces: [CGRect] = []
    if overlap.minY > rect.minY {
      pieces.append(
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY))
    }
    if overlap.maxY < rect.maxY {
      pieces.append(
        CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
    }
    if overlap.minX > rect.minX {
      pieces.append(
        CGRect(
          x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height))
    }
    if overlap.maxX < rect.maxX {
      pieces.append(
        CGRect(
          x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
      )
    }
    return pieces
  }
}

/// Black dimming layer restricted to the same mask image as the blur.
public final class DimView: NSView {
  public var mask: NSImage? { didSet { needsDisplay = true } }
  public var dimAlpha: CGFloat = 0 { didSet { needsDisplay = true } }

  override public var isFlipped: Bool { true }

  override public func draw(_ dirtyRect: NSRect) {
    guard dimAlpha > 0, let mask else { return }
    mask.draw(in: bounds)
    NSColor.black.withAlphaComponent(dimAlpha).setFill()
    bounds.fill(using: .sourceIn)
  }
}

@MainActor
public enum HitTest {
  /// Window number that would receive a mouse-down at a Quartz point.
  /// https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)
  public static func windowNumber(atQuartz point: CGPoint) -> Int {
    NSWindow.windowNumber(at: Coordinates.appKit(fromQuartz: point), belowWindowWithWindowNumber: 0)
  }
}
