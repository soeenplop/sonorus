import AppKit

/// Borderless overlay covering exactly one display. It becomes key to receive
/// keyboard input but, being a non-activating panel, never activates Sonorus
/// or steals the active application from the user.
final class SelectionOverlayPanel: NSPanel {
  init(frame: NSRect) {
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .screenSaver
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    animationBehavior = .none
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Keeps the panel exactly on its display instead of below the menu bar.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
