import AppKit

/// Gradual blur-in of the outgoing focus for `--blur window`.
///
/// Observed (user, 17.11.2026): the WindowServer radius blurs a window's whole
/// rectangle regardless of drawn alpha, and moving the main surface above the
/// outgoing window while it holds a hole there shows a stale, white-rimmed
/// backdrop. So the main surface stays below the outgoing window during the
/// ramp; this panel sits directly above that window (still below the new
/// focus) and ramps its radius from 0. The caller reorders the main surface
/// when the ramp ends, which equals the clean instant switch.
@MainActor
public final class WindowBlurTransition {
  public let panel: RoundedOverlayPanel
  private let dim = CAShapeLayer()
  private var timer: Timer?
  private var started = 0.0
  private var duration = 0.0
  private var radius: CGFloat = 0
  private var dimAlpha: CGFloat = 0
  private var completion: (@MainActor () -> Void)?

  public init(level: NSWindow.Level) {
    panel = RoundedOverlayPanel(level: level)
    let host = NSView(frame: panel.contentLayoutRect)
    host.wantsLayer = true
    host.layer?.addSublayer(dim)
    panel.contentView = host
  }

  public var isRunning: Bool { timer != nil }

  /// `quartzRect` is the outgoing window's visible frame on this display.
  public func start(
    covering quartzRect: CGRect, above windowID: CGWindowID, level: NSWindow.Level,
    radius: CGFloat, dimAlpha: CGFloat, cornerRadius: CGFloat, duration: Double,
    completion: @escaping @MainActor () -> Void
  ) {
    cancel()
    self.radius = radius
    self.dimAlpha = dimAlpha
    self.duration = duration
    self.completion = completion
    let frame = Coordinates.appKit(fromQuartz: quartzRect).integral
    let local = CGRect(origin: .zero, size: frame.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.level = level
    panel.setFrame(frame, display: false)
    panel.contentView?.frame = local
    dim.frame = local
    // The panel's system corner shape clips the dim like the blur.
    dim.path = CGPath(rect: local, transform: nil)
    dim.fillColor = NSColor.black.withAlphaComponent(0).cgColor
    CATransaction.commit()
    WindowBlur.apply(radius: 0, to: panel)
    panel.order(.above, relativeTo: Int(windowID))
    started = ProcessInfo.processInfo.systemUptime
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
  }

  /// Stops without running the completion (Space change, teardown).
  public func cancel() {
    timer?.invalidate()
    timer = nil
    completion = nil
    remove()
  }

  /// Ends a running ramp now and lets the caller reorder (rapid switches).
  public func finish() {
    guard isRunning else { return }
    timer?.invalidate()
    timer = nil
    complete()
  }

  private func step() {
    let progress = FocusTransition.progress(
      elapsed: ProcessInfo.processInfo.systemUptime - started, duration: duration)
    WindowBlur.apply(radius: Int((radius * progress).rounded()), to: panel)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dim.fillColor = NSColor.black.withAlphaComponent(dimAlpha * progress).cgColor
    CATransaction.commit()
    guard progress >= 1 else { return }
    timer?.invalidate()
    timer = nil
    complete()
  }

  /// The caller moves the main surface above the outgoing window first; this
  /// panel leaves a frame later, so the region is never shown unblurred.
  private func complete() {
    let done = completion
    completion = nil
    done?()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isRunning else { return }
        self.remove()
      }
    }
  }

  private func remove() {
    guard panel.isVisible else { return }
    WindowBlur.apply(radius: 0, to: panel)
    panel.orderOut(nil)
  }
}

/// Click-through panel with the system window corner shape. A borderless
/// panel is a hard rectangle for the WindowServer blur (user: square corners
/// on the outgoing window); a titled, chrome-less panel gets the same rounded
/// shape as ordinary app windows.
@MainActor
public final class RoundedOverlayPanel: NSPanel {
  public init(level: NSWindow.Level) {
    super.init(
      contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered,
      defer: false)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    ignoresMouseEvents = true
    self.level = level
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .none
  }

  override public var canBecomeKey: Bool { false }
  override public var canBecomeMain: Bool { false }
  /// Titled windows are kept below the menu bar by default; the ramp must
  /// match the outgoing window's frame exactly.
  override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
