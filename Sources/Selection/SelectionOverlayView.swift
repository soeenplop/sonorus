import AppKit
import Contracts

/// Thin AppKit shell over the engine: forwards pointer and key events in global
/// Quartz points and draws the scene part that lies on its own display.
///
/// The view is flipped, so its local space already is top-left based like Quartz.
final class SelectionOverlayView: NSView {
  /// Almost invisible, but not fully transparent: pixels with zero alpha let
  /// clicks fall through to the real window below.
  private static let hitCatcher = NSColor(white: 0, alpha: 0.02)
  private static let scrim = NSColor(white: 0, alpha: 0.28)

  let display: DisplaySnapshot
  let toolbar = SelectionToolbarView()
  var onPointer: (SelectionPointerEvent) -> Void = { _ in }
  var onCommand: (SelectionCommand) -> Void = { _ in }
  var cursorProvider: (ScreenPoint) -> NSCursor = { _ in .crosshair }
  var scene: SelectionScene {
    didSet {
      toolbar.update(with: scene)
      needsDisplay = true
      updateAccessibility(previous: oldValue)
    }
  }

  private var accent: NSColor { .controlAccentColor }

  init(display: DisplaySnapshot, scene: SelectionScene) {
    self.display = display
    self.scene = scene
    super.init(frame: NSRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height))
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(toolbar)
    NSLayoutConstraint.activate([
      toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
      toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 56),
    ])
    toolbar.onCommand = { [weak self] in self?.onCommand($0) }
    toolbar.update(with: scene)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    updateAccessibility(previous: nil)
  }

  /// Every display has an overlay; only the key one announces changes.
  private func updateAccessibility(previous: SelectionScene?) {
    setAccessibilityLabel("Selection: \(scene.selectionSummary)")
    setAccessibilityHelp(scene.accessibilityHelp)
    guard let previous, window?.isKeyWindow == true,
      previous.mode != scene.mode || previous.selectionSummary != scene.selectionSummary
    else { return }
    NSAccessibility.post(
      element: self, notification: .announcementRequested,
      userInfo: [
        .announcement: scene.selectionSummary,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: Events

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [
          .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect,
        ],
        owner: self, userInfo: nil))
  }

  private func globalPoint(of event: NSEvent) -> ScreenPoint {
    let local = convert(event.locationInWindow, from: nil)
    return SelectionCoordinateSpace.globalPoint(
      forLocal: ScreenPoint(x: local.x, y: local.y), in: display.frame)
  }

  private func becomeKeyIfNeeded() {
    guard let window, !window.isKeyWindow else { return }
    window.makeKey()
    window.makeFirstResponder(self)
  }

  override func mouseEntered(with event: NSEvent) { becomeKeyIfNeeded() }

  /// The toolbar background passes unhandled clicks up to this view, and the
  /// tracking area reports moves over it; neither may reach the window below.
  private func isOverToolbar(_ event: NSEvent) -> Bool {
    !toolbar.isHidden && toolbar.frame.contains(convert(event.locationInWindow, from: nil))
  }

  /// Set when a press started on the toolbar, so its drag and release are ignored too.
  private var isPressOnToolbar = false

  override func cursorUpdate(with event: NSEvent) {
    if isOverToolbar(event) {
      NSCursor.arrow.set()
    } else {
      cursorProvider(globalPoint(of: event)).set()
    }
  }

  override func mouseMoved(with event: NSEvent) {
    becomeKeyIfNeeded()
    if isOverToolbar(event) {
      onPointer(.left)
      NSCursor.arrow.set()
      return
    }
    let point = globalPoint(of: event)
    onPointer(.moved(point))
    cursorProvider(point).set()
  }

  override func mouseDown(with event: NSEvent) {
    becomeKeyIfNeeded()
    isPressOnToolbar = isOverToolbar(event)
    guard !isPressOnToolbar else { return }
    onPointer(
      .down(globalPoint(of: event), startsNewRegion: event.modifierFlags.contains(.option)))
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isPressOnToolbar else { return }
    let point = globalPoint(of: event)
    onPointer(.dragged(point))
    cursorProvider(point).set()
  }

  override func mouseUp(with event: NSEvent) {
    guard !isPressOnToolbar else {
      isPressOnToolbar = false
      return
    }
    onPointer(.up(globalPoint(of: event)))
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: onCommand(.confirm)  // Return, keypad Enter
    case 53: onCommand(.cancel)  // Escape
    case 51, 117: onCommand(.deleteRegion)  // Delete, forward delete
    case 49: onCommand(.toggleRegion)  // Space
    case 48: onCommand(.nextRegion(backward: event.modifierFlags.contains(.shift)))  // Tab
    case 18: onCommand(.setMode(.windows))
    case 19: onCommand(.setMode(.displays))
    case 20: onCommand(.setMode(.regions))
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCommand(.cancel) }

  // MARK: Drawing

  private func local(_ frame: ScreenRect) -> NSRect {
    NSRect(
      x: frame.x - display.frame.x, y: frame.y - display.frame.y, width: frame.width,
      height: frame.height)
  }

  private func local(_ point: ScreenPoint) -> NSPoint {
    NSPoint(x: point.x - display.frame.x, y: point.y - display.frame.y)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.set()
    bounds.fill(using: .copy)
    Self.scrim.set()
    bounds.fill()

    switch scene.mode {
    case .windows: drawWindows()
    case .displays: drawDisplays()
    case .regions: drawRegions()
    }
    drawDisplayLabel()
    drawToolbarBackdrop()
  }

  /// Dark, shadowed plate below the toolbar, so it stands out from the
  /// scrim and from highlighted windows alike.
  private func drawToolbarBackdrop() {
    guard !toolbar.isHidden else { return }
    let path = NSBezierPath(
      roundedRect: toolbar.frame, xRadius: SelectionToolbarView.cornerRadius,
      yRadius: SelectionToolbarView.cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    NSColor(white: 0.08, alpha: 0.85).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  /// Brightens `rect` back to the desktop so the target looks lifted out of the scrim.
  private func cutOut(_ rect: NSRect) {
    Self.hitCatcher.set()
    rect.fill(using: .copy)
  }

  private func drawWindows() {
    for mark in scene.windows {
      let rect = local(mark.frame)
      guard rect.intersects(bounds) else { continue }
      cutOut(rect)
      accent.withAlphaComponent(mark.isSelected ? 0.28 : 0.14).setFill()
      rect.fill()
      accent.setStroke()
      let path = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
      path.lineWidth = mark.isHovered ? 4 : 3
      path.stroke()
      if mark.isSelected {
        drawLabel("✓ Stays sharp", at: NSPoint(x: rect.minX + 10, y: rect.minY + 10))
      }
    }
  }

  private func drawDisplays() {
    for mark in scene.displays where mark.runtimeID == display.runtimeID {
      let rect = bounds
      if mark.isAmbiguous {
        drawCenteredLabel(title: mark.name, subtitle: SelectionScene.ambiguousDisplayLabel)
        continue
      }
      if mark.isHovered || mark.isSelected {
        cutOut(rect)
        accent.withAlphaComponent(mark.isSelected ? 0.22 : 0.1).setFill()
        rect.fill()
        accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 3, dy: 3))
        path.lineWidth = mark.isHovered ? 6 : 4
        path.stroke()
      }
      let title = mark.isSelected ? "✓ \(mark.name)" : mark.name
      let subtitle = String(
        format: "%.0f × %.0f pt · %.0f×", mark.frame.width, mark.frame.height, mark.scale)
      drawCenteredLabel(title: title, subtitle: subtitle)
    }
  }

  private func drawRegions() {
    for mark in scene.regions where mark.displayID == display.id {
      let rect = local(mark.frame)
      cutOut(rect)
      let tint = mark.isEnabled ? accent : NSColor.systemGray
      tint.withAlphaComponent(mark.isEnabled ? 0.14 : 0.1).setFill()
      rect.fill()
      tint.setStroke()
      let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
      path.lineWidth = mark.isSelected ? 3 : 2
      if !mark.isEnabled { path.setLineDash([6, 4], count: 2, phase: 0) }
      path.stroke()
      if mark.isSelected {
        let suffix = mark.isEnabled ? "" : " · disabled"
        drawLabel(mark.sizeLabel + suffix, at: labelOrigin(above: rect))
      } else if !mark.isEnabled {
        drawLabel("disabled", at: NSPoint(x: rect.minX + 6, y: rect.minY + 6))
      }
    }
    for mark in scene.handles
    where scene.regions.contains(where: { $0.isSelected && $0.displayID == display.id }) {
      drawHandle(at: local(mark.position))
    }
    if let preview = scene.preview, preview.displayID == display.id {
      let rect = local(preview.frame)
      cutOut(rect)
      accent.withAlphaComponent(0.12).setFill()
      rect.fill()
      accent.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 2
      path.setLineDash([6, 4], count: 2, phase: 0)
      path.stroke()
      drawLabel(preview.sizeLabel, at: labelOrigin(above: rect))
    }
  }

  private func labelOrigin(above rect: NSRect) -> NSPoint {
    let y = rect.minY >= 30 ? rect.minY - 26 : rect.minY + 6
    return NSPoint(x: max(rect.minX, 6), y: y)
  }

  private func drawHandle(at point: NSPoint) {
    let size: CGFloat = 9
    let square = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    NSColor.white.setFill()
    square.fill()
    accent.setStroke()
    let outline = NSBezierPath(rect: square)
    outline.lineWidth = 1.5
    outline.stroke()
  }

  private func drawDisplayLabel() {
    guard scene.mode != .displays,
      let mark = scene.displays.first(where: { $0.runtimeID == display.runtimeID })
    else { return }
    drawLabel(mark.name, at: NSPoint(x: 16, y: 16))
    if mark.isAmbiguous, scene.mode == .regions {
      drawCenteredLabel(title: mark.name, subtitle: SelectionScene.ambiguousDisplayLabel)
    }
  }

  private static func pillAttributes(size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString
    .Key: Any]
  {
    [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: NSColor.white,
    ]
  }

  private func drawLabel(_ text: String, at origin: NSPoint) {
    let string = NSAttributedString(
      string: text, attributes: Self.pillAttributes(size: 12, weight: .semibold))
    let size = string.size()
    let pill = NSRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 8)
    NSColor(white: 0, alpha: 0.7).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
    string.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4))
  }

  private func drawCenteredLabel(title: String, subtitle: String) {
    let titleString = NSAttributedString(
      string: title, attributes: Self.pillAttributes(size: 34, weight: .semibold))
    let subtitleString = NSAttributedString(
      string: subtitle, attributes: Self.pillAttributes(size: 15, weight: .regular))
    let titleSize = titleString.size()
    let subtitleSize = subtitleString.size()
    let width = max(titleSize.width, subtitleSize.width) + 48
    let height = titleSize.height + subtitleSize.height + 36
    let pill = NSRect(
      x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    NSColor(white: 0, alpha: 0.6).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 16, yRadius: 16).fill()
    titleString.draw(at: NSPoint(x: pill.midX - titleSize.width / 2, y: pill.minY + 16))
    subtitleString.draw(
      at: NSPoint(x: pill.midX - subtitleSize.width / 2, y: pill.minY + 20 + titleSize.height))
  }
}
