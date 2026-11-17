import AppKit
import QuartzCore

/// Borderless, non-activating, click-through panel that never becomes key or
/// main and stays on every Space.
final class EffectPanel: NSPanel {
  init(frame: CGRect) {
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    level = .normal
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .none
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

extension NSWindow.Level {
  static let aboveNormal = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
}

@MainActor
final class PanelSurface: EffectSurface {
  private let panel: EffectPanel
  private let content: EffectContentView

  init(frame: CGRect, scale: Double, blur: EffectContentView.Blur) {
    panel = EffectPanel(frame: frame)
    content = EffectContentView(
      frame: CGRect(origin: .zero, size: frame.size), blur: blur)
    panel.contentView = content
  }

  var windowID: UInt32 { UInt32(clamping: panel.windowNumber) }

  func setFrame(_ frame: CGRect, scale: Double) {
    panel.setFrame(frame, display: false)
  }

  func order(below windowID: UInt32) {
    panel.level = .normal
    panel.order(.below, relativeTo: Int(windowID))
  }

  func orderAboveNormalWindows() {
    panel.level = .aboveNormal
    panel.orderFrontRegardless()
  }

  func hide() { panel.orderOut(nil) }
  func setMask(_ mask: SurfaceMask) { content.setMask(mask) }
  func setValues(_ values: SurfaceValues) { content.setValues(values) }
  func animate(_ animation: SurfaceAnimation) { content.animate(animation) }

  func close() {
    content.setValues(.zero)
    panel.orderOut(nil)
    panel.close()
  }
}

@MainActor
final class PanelSurfaceFactory: EffectSurfaceMaking {
  let usesFallbackBlur: Bool
  private let disablesOccludedBackdropBlurs: Bool?

  /// `disablesOccludedBackdropBlurs` nil keeps the system default.
  init(disablesOccludedBackdropBlurs: Bool? = nil) {
    self.disablesOccludedBackdropBlurs = disablesOccludedBackdropBlurs
    usesFallbackBlur = BackdropBlur.makeLayer() == nil
  }

  func makeSurface(frame: CGRect, scale: Double) -> (any EffectSurface)? {
    let blur: EffectContentView.Blur
    if !usesFallbackBlur,
      let layer = BackdropBlur.makeLayer(disablesOccludedBlurs: disablesOccludedBackdropBlurs)
    {
      blur = .backdrop(layer)
    } else {
      blur = .material(EffectContentView.makeMaterialView())
    }
    return PanelSurface(frame: frame, scale: scale, blur: blur)
  }

  func performAtomically(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
  }
}
