import AppKit
import Contracts

/// Live `DesktopProviding`: window list, focus and displays in one immutable
/// snapshot per change.
///
/// Refresh happens every `Timing.pollInterval`, immediately on workspace
/// events, and at `Timing.burstInterval` for `Timing.burstDuration` after
/// activations and Space changes: a raised window may reach the front of the
/// window list a few frames after the event. A snapshot (with the next
/// revision) is only published when its content differs from the previous one.
///
/// No permission is needed: focus is the frontmost window of the frontmost
/// application, guessed from the window order and therefore `.uncertain`.
@MainActor
public final class DesktopTracker: DesktopProviding {
  public struct Timing: Equatable, Sendable {
    public var pollInterval: TimeInterval
    public var burstInterval: TimeInterval
    public var burstDuration: TimeInterval

    public init(
      pollInterval: TimeInterval = 0.1, burstInterval: TimeInterval = 1.0 / 60,
      burstDuration: TimeInterval = 0.5
    ) {
      self.pollInterval = pollInterval
      self.burstInterval = burstInterval
      self.burstDuration = burstDuration
    }
  }

  public private(set) var currentSnapshot: DesktopSnapshot?

  private let displays: any DisplayProviding
  private let windowSource: any WindowListSource
  private let focusSource: any FocusSource
  private let events: any DesktopEventSource
  private let timers: any TimerScheduling
  private let separateSpaces: @MainActor () -> Bool
  private let timing: Timing
  private var catalog: WindowCatalog
  private var focus: FocusTracker
  private var bundleIDs: [Int32: String?] = [:]
  private var continuations: [UUID: AsyncStream<DesktopSnapshot>.Continuation] = [:]
  private var pollTimer: (any RepeatingTimer)?
  private var burstTimer: (any RepeatingTimer)?
  private var burstTicksRemaining = 0
  private(set) var isRunning = false

  /// - Parameter displays: usually `Displays.DisplayManager`, started by the caller.
  public convenience init(displays: any DisplayProviding, timing: Timing = Timing()) {
    self.init(
      displays: displays, windowSource: CGWindowListSource(),
      focusSource: WorkspaceFocusSource(), events: WorkspaceEventSource(),
      timers: RunLoopTimers(), separateSpaces: { NSScreen.screensHaveSeparateSpaces },
      ownPID: getpid(), timing: timing)
  }

  init(
    displays: any DisplayProviding, windowSource: any WindowListSource,
    focusSource: any FocusSource, events: any DesktopEventSource, timers: any TimerScheduling,
    separateSpaces: @escaping @MainActor () -> Bool, ownPID: Int32, timing: Timing = Timing()
  ) {
    self.displays = displays
    self.windowSource = windowSource
    self.focusSource = focusSource
    self.events = events
    self.timers = timers
    self.separateSpaces = separateSpaces
    self.timing = timing
    self.catalog = WindowCatalog(ownPID: ownPID)
    self.focus = FocusTracker(ownPID: ownPID)
  }

  public func start() async throws {
    guard !isRunning else { return }
    isRunning = true
    events.start { [weak self] event in self?.handle(event) }
    pollTimer = timers.repeating(every: timing.pollInterval) { [weak self] in self?.refresh() }
    refresh()
  }

  public func stop() {
    guard isRunning else { return }
    isRunning = false
    events.stop()
    pollTimer?.cancel()
    pollTimer = nil
    stopBurst()
    focus.unfreeze()
    for continuation in continuations.values { continuation.finish() }
    continuations.removeAll()
  }

  public func updates() -> AsyncStream<DesktopSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<DesktopSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    continuations[id] = continuation
    if let currentSnapshot { continuation.yield(currentSnapshot) }
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  /// Keeps the current work window while Sonorus' own UI is active. Window
  /// and display changes are still published; the target is dropped only if
  /// its window disappears.
  public func beginFocusFreeze() {
    focus.freeze()
  }

  public func endFocusFreeze() async {
    focus.unfreeze()
    guard isRunning else { return }
    refresh()
    startBurst()
  }

  func handle(_ event: DesktopEvent) {
    guard isRunning else { return }
    refresh()
    if event.startsBurst { startBurst() }
  }

  func refresh() {
    guard isRunning else { return }
    let displayList = displays.currentDisplays()
    let records = WindowListParser.parse(windowSource.onScreenWindows())
    pruneBundleIDs(keeping: Set(records.map(\.ownerPID)))
    let windows = catalog.update(
      records: records,
      existing: { [windowSource] in WindowListParser.parse(windowSource.describeWindows($0)) },
      bundleID: bundleID(for:), displays: displayList.map(\.frame),
      separateSpaces: separateSpaces())
    let state = focus.resolve(frontmostPID: focusSource.frontmostApplicationPID(), windows: windows)
    publish(
      displays: displayList, windows: windows.map(\.snapshot), focus: state)
  }

  private func publish(displays: [DisplaySnapshot], windows: [WindowSnapshot], focus: FocusState) {
    let previous = currentSnapshot?.revision ?? 0
    let candidate = DesktopSnapshot(
      revision: previous, displays: displays, windows: windows, focusedWindow: focus.window,
      focusConfidence: focus.confidence)
    guard candidate != currentSnapshot else { return }
    let snapshot = DesktopSnapshot(
      revision: previous + 1, displays: displays, windows: windows, focusedWindow: focus.window,
      focusConfidence: focus.confidence)
    currentSnapshot = snapshot
    for continuation in continuations.values { continuation.yield(snapshot) }
  }

  private func startBurst() {
    burstTicksRemaining = max(1, Int((timing.burstDuration / timing.burstInterval).rounded()))
    guard burstTimer == nil else { return }
    burstTimer = timers.repeating(every: timing.burstInterval) { [weak self] in
      self?.burstTick()
    }
  }

  private func burstTick() {
    burstTicksRemaining -= 1
    if burstTicksRemaining <= 0 { stopBurst() }
    refresh()
  }

  private func stopBurst() {
    burstTimer?.cancel()
    burstTimer = nil
    burstTicksRemaining = 0
  }

  private func bundleID(for pid: Int32) -> String? {
    if let cached = bundleIDs[pid] { return cached }
    let bundleID = windowSource.bundleIdentifier(for: pid)
    bundleIDs[pid] = bundleID
    return bundleID
  }

  private func pruneBundleIDs(keeping pids: Set<Int32>) {
    bundleIDs = bundleIDs.filter { pids.contains($0.key) }
  }
}
