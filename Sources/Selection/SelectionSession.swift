import AppKit
import Contracts

/// One live selection pass: owns the engine, one overlay panel per display and
/// the glue between them. Everything here is AppKit plumbing; the rules live in
/// `SelectionEngine`. Not exercised by tests because it needs a live desktop.
@MainActor
final class SelectionSession {
  private var engine: SelectionEngine
  private var overlays: [(panel: SelectionOverlayPanel, view: SelectionOverlayView)] = []
  private var screenChangeTask: Task<Void, Never>?
  private var onFinish: (@MainActor (SelectionOutcome) -> Void)?
  private var isTornDown = false
  private var isFinishScheduled = false

  init(
    request: SelectionRequest, excludedOwnerPIDs: Set<Int32>,
    onFinish: @escaping @MainActor (SelectionOutcome) -> Void
  ) {
    engine = SelectionEngine(request: request, excludedOwnerPIDs: excludedOwnerPIDs)
    self.onFinish = onFinish
  }

  // MARK: Lifecycle

  func present() {
    let displays = engine.desktop.displays
    let primaryHeight =
      SelectionCoordinateSpace.primaryHeight(of: displays)
      ?? NSScreen.screens.first?.frame.height ?? displays.map(\.frame.height).max() ?? 0

    let mouse = NSEvent.mouseLocation
    let startPoint = ScreenPoint(x: mouse.x, y: primaryHeight - mouse.y)
    engine.pointerMoved(to: startPoint)
    let scene = engine.scene

    for display in displays {
      let frame = SelectionCoordinateSpace.appKitFrame(
        forQuartz: display.frame, primaryHeight: primaryHeight)
      let panel = SelectionOverlayPanel(
        frame: NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
      let view = SelectionOverlayView(display: display, scene: scene)
      view.onPointer = { [weak self] in self?.handle($0) }
      view.onCommand = { [weak self] in self?.handle($0) }
      view.cursorProvider = { [weak self] point in
        self?.engine.cursor(at: point).nsCursor ?? .crosshair
      }
      panel.contentView = view
      overlays.append((panel, view))
    }

    let keyIndex = displays.firstIndex { $0.frame.containsHalfOpen(startPoint) } ?? 0
    for (index, overlay) in overlays.enumerated() where index != keyIndex {
      overlay.panel.orderFrontRegardless()
    }
    if overlays.indices.contains(keyIndex) {
      let overlay = overlays[keyIndex]
      overlay.panel.makeKeyAndOrderFront(nil)
      overlay.panel.makeFirstResponder(overlay.view)
    }
    NSCursor.crosshair.set()

    // Cached geometry would be wrong after a display change; abort instead of guessing.
    // Notifications that leave displays and frames as they were are ignored.
    screenChangeTask = Task { [weak self] in
      let notifications = NotificationCenter.default.notifications(
        named: NSApplication.didChangeScreenParametersNotification)
      for await _ in notifications {
        guard let self else { return }
        if SelectionDisplayLayout.hasChanged(
          from: self.engine.desktop.displays, to: Self.currentDisplayLayout())
        {
          self.handle(.cancel)
        }
      }
    }
  }

  /// Live displays as runtime ID and Quartz frame, the same space as the snapshot.
  private static func currentDisplayLayout() -> Set<SelectionDisplayLayout.Entry> {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return Set(
      NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let id = number.uint32Value
        let bounds = CGDisplayBounds(id)
        return SelectionDisplayLayout.Entry(
          runtimeID: id,
          frame: ScreenRect(
            x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height))
      })
  }

  /// Removes every window and observer. Safe to call more than once.
  func tearDown() {
    guard !isTornDown else { return }
    isTornDown = true
    screenChangeTask?.cancel()
    screenChangeTask = nil
    onFinish = nil
    for overlay in overlays {
      overlay.view.onPointer = { _ in }
      overlay.view.onCommand = { _ in }
      overlay.view.toolbar.onCommand = { _ in }
      overlay.panel.orderOut(nil)
      overlay.panel.contentView = nil
      overlay.panel.close()
    }
    overlays.removeAll()
    NSCursor.arrow.set()
  }

  // MARK: Input

  private func handle(_ event: SelectionPointerEvent) {
    engine.apply(event)
    didApply()
  }

  private func handle(_ command: SelectionCommand) {
    engine.apply(command)
    didApply()
  }

  private func didApply() {
    guard !isTornDown else { return }
    let scene = engine.scene
    for overlay in overlays where overlay.view.scene != scene { overlay.view.scene = scene }
    if let pointer = engine.pointer { engine.cursor(at: pointer).nsCursor.set() }
    guard let outcome = engine.outcome, !isFinishScheduled else { return }
    isFinishScheduled = true
    // Finish outside the event handler that produced the outcome.
    Task { [weak self] in
      guard let self, !self.isTornDown, let finish = self.onFinish else { return }
      finish(outcome)
    }
  }
}

extension SelectionCursor {
  var nsCursor: NSCursor {
    switch self {
    case .crosshair: return .crosshair
    case .move: return .openHand
    case .resize(let handle):
      return NSCursor.frameResize(position: handle.framePosition, directions: .all)
    }
  }
}

extension RegionHandle {
  fileprivate var framePosition: NSCursor.FrameResizePosition {
    switch self {
    case .topLeft: return .topLeft
    case .top: return .top
    case .topRight: return .topRight
    case .right: return .right
    case .bottomRight: return .bottomRight
    case .bottom: return .bottom
    case .bottomLeft: return .bottomLeft
    case .left: return .left
    }
  }
}
