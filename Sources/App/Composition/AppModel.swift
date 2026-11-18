import AppKit
import Contracts
import Displays
import MenuBar
import Observation
import Persistence
import Rendering
import Rules
import Selection
import WindowSystem

/// Composition root: desktop snapshots flow through the rules into the
/// renderer; both UIs act on this object and receive plain state back.
/// No permission is needed: focus is guessed from the window order
/// (`.uncertain`), which the rules accept.
@MainActor
@Observable
final class AppModel: FocusControlling {
  @ObservationIgnored private let displays = DisplayManager()
  @ObservationIgnored private let desktop: DesktopTracker
  @ObservationIgnored private let renderer = BackdropRenderer()
  @ObservationIgnored private let resolver = EffectResolver()
  @ObservationIgnored private let selection = DirectSelectionPresenter()
  @ObservationIgnored private let store: FileConfigurationStore?
  @ObservationIgnored private var session = FocusSession()
  @ObservationIgnored private var snapshot: DesktopSnapshot?
  @ObservationIgnored private var isSelecting = false
  @ObservationIgnored private var renderTask: Task<Void, Never>?
  @ObservationIgnored private var needsRender = false
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []

  private(set) var menu: MenuBarViewModel!

  init() {
    desktop = DesktopTracker(displays: displays)
    store = try? FileConfigurationStore()
    menu = MenuBarViewModel(controller: self)
    Task { await start() }
  }

  // MARK: Lifecycle

  private func start() async {
    if let loaded = try? await store?.load() { session.configuration = loaded }
    displays.start()
    pushState()
    updateActivity()
    do {
      try await desktop.start()
    } catch {
      return
    }
    tasks.append(
      Task { [weak self] in
        guard let updates = self?.desktop.updates() else { return }
        for await snapshot in updates { self?.receive(snapshot) }
      })
    tasks.append(
      Task { [weak self] in
        guard let changes = self?.displays.changes() else { return }
        for await _ in changes { self?.pushState() }
      })
  }

  private func receive(_ snapshot: DesktopSnapshot) {
    self.snapshot = snapshot
    // Exceptions last until their window closes; a quit owner ends them all.
    let before = session.exceptions
    session.exceptions = session.exceptions.filter {
      NSRunningApplication(processIdentifier: $0.ownerPID) != nil
    }
    if session.exceptions != before { pushState() }
    scheduleRender()
  }

  // MARK: Rendering

  /// Renders the latest snapshot; changes during a render coalesce into one more.
  private func scheduleRender() {
    needsRender = true
    guard renderTask == nil else { return }
    renderTask = Task { [weak self] in
      while let self, self.needsRender {
        self.needsRender = false
        await self.renderNow()
      }
      self?.renderTask = nil
    }
  }

  private func renderNow() async {
    guard let snapshot else { return }
    var shown = session
    // The selection overlay replaces the effect until it is confirmed or cancelled.
    if isSelecting { shown.configuration.isEnabled = false }
    let scene = resolver.resolve(desktop: snapshot, session: shown)
    try? await renderer.render(scene, desktop: snapshot)
    debugLog(snapshot, scene)
  }

  /// `SONORUS_DEBUG=1 .build/Sonorus.app/Contents/MacOS/Sonorus` prints one
  /// line per changed render; window titles and contents are never logged.
  @ObservationIgnored private let isDebugging =
    ProcessInfo.processInfo.environment["SONORUS_DEBUG"] == "1"
  @ObservationIgnored private var lastDebugLine = ""

  private func debugLog(_ snapshot: DesktopSnapshot, _ scene: RenderScene) {
    guard isDebugging else { return }
    let focus = snapshot.focusedWindow.map { "#\($0.windowID) pid \($0.ownerPID)" } ?? "none"
    let anchor = scene.anchor.map { "#\($0.window.windowID) group \($0.group.count)" } ?? "none"
    let masks = scene.masks.map {
      "\($0.placement.runtimeID): anchored \($0.anchored.count) overlay \($0.overlay.count)"
    }.joined(separator: ", ")
    let line =
      "focus \(focus) [\(snapshot.focusConfidence)] anchor \(anchor) masks [\(masks)] "
      + "exceptions \(session.exceptions.map { "#\($0.windowID)" }.sorted()) -> "
      + renderer.debugSummary
    guard line != lastDebugLine else { return }
    lastDebugLine = line
    let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    FileHandle.standardError.write(Data("[\(stamp)] \(line)\n".utf8))
  }

  // MARK: State for the UIs

  private func pushState() {
    let connected = displays.currentDisplays()
    let exceptions = session.exceptions.sorted { $0.windowID < $1.windowID }
    let appNames = exceptions.map {
      NSRunningApplication(processIdentifier: $0.ownerPID)?.localizedName
    }
    menu.apply(
      MenuBarState(
        configuration: session.configuration,
        exceptions: zip(exceptions, appNames).map {
          MenuBarException(reference: $0, appName: $1)
        },
        displays: connected.map { MenuBarDisplay(id: $0.id, name: $0.name) },
        usesFallbackBlur: renderer.isUsingFallbackBlur))
  }

  /// Applies a configuration change everywhere and saves it.
  private func update(_ change: (inout FocusConfiguration) -> Void) {
    change(&session.configuration)
    save()
    updateActivity()
    pushState()
    scheduleRender()
  }

  /// The window list only needs close tracking while something is shown.
  private func updateActivity() {
    desktop.isIdle = !session.configuration.isEnabled && !isSelecting
  }

  private func save() {
    let configuration = session.configuration
    Task { [store] in try? await store?.save(configuration) }
  }

  // MARK: FocusControlling

  func setEnabled(_ isEnabled: Bool) {
    update { $0.isEnabled = isEnabled }
  }

  func setScope(_ scope: EffectScope) {
    update { $0.scope = scope }
  }

  func startSelection(_ mode: SelectionMode) {
    guard !isSelecting else { return }
    isSelecting = true
    updateActivity()  // refreshes the snapshot when the tracker was idle
    guard let snapshot = desktop.currentSnapshot else {
      isSelecting = false
      updateActivity()
      return
    }
    // The popover would otherwise stay above the selection overlay.
    NSApp.keyWindow?.orderOut(nil)
    desktop.beginFocusFreeze()
    scheduleRender()
    let displaysInScope: Set<DisplayID>
    if case .displays(let selected) = session.configuration.scope {
      displaysInScope = selected
    } else {
      displaysInScope = []
    }
    let request = SelectionRequest(
      mode: mode, desktop: snapshot,
      draft: SelectionDraft(
        windows: session.exceptions, displays: displaysInScope,
        regions: session.configuration.regions))
    Task {
      let outcome = await selection.select(request)
      if case .confirmed(let draft, let endMode) = outcome {
        let before = session.configuration
        session.apply(draft, original: request.draft, startMode: mode, endMode: endMode)
        if session.configuration != before { save() }
      }
      isSelecting = false
      updateActivity()
      await desktop.endFocusFreeze()
      pushState()
      scheduleRender()
    }
  }

  func previewEffects(_ effects: EffectSettings) {
    session.configuration.effects = effects
    scheduleRender()
  }

  func commitEffects(_ effects: EffectSettings) {
    update { $0.effects = effects }
  }

  func removeException(_ window: WindowReference) {
    session.exceptions.remove(window)
    pushState()
    scheduleRender()
  }

  func quit() {
    menu.flushPendingCommit()
    selection.cancel()
    renderer.stop()
    desktop.stop()
    let configuration = session.configuration
    Task { [store] in
      try? await store?.save(configuration)
      NSApplication.shared.terminate(nil)
    }
  }
}
