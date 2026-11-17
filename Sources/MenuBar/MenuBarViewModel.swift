import Contracts
import Foundation
import Observation

/// The three alternative effect scopes as the picker shows them.
public enum ScopeChoice: CaseIterable, Identifiable, Equatable, Sendable {
  case allDisplays
  case displays
  case regions

  public var id: Self { self }

  public var title: String {
    switch self {
    case .allDisplays: "All Displays"
    case .displays: "Selected Displays"
    case .regions: "Regions"
    }
  }

  /// Selection that picks the targets of this scope; none for all displays.
  public var selectionMode: SelectionMode? {
    switch self {
    case .allDisplays: nil
    case .displays: .displays
    case .regions: .regions
    }
  }

  public var selectionButtonTitle: String? {
    switch self {
    case .allDisplays: nil
    case .displays: "Select Displays…"
    case .regions: "Edit Regions…"
    }
  }

  public init(_ scope: EffectScope) {
    switch scope {
    case .allDisplays: self = .allDisplays
    case .displays: self = .displays
    case .regions: self = .regions
    }
  }
}

/// Logic of the menu bar popover without any UI. Slider changes reach the
/// controller live through `previewEffects` and are saved once, debounced,
/// through `commitEffects`.
@MainActor
@Observable
public final class MenuBarViewModel {
  public static let defaultDebounce: Duration = .milliseconds(400)

  public private(set) var state: MenuBarState

  @ObservationIgnored private let controller: any FocusControlling
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private var pendingEffects: EffectSettings?
  @ObservationIgnored private var lastDisplaySelection: Set<DisplayID> = []
  @ObservationIgnored var commitTask: Task<Void, Never>?

  /// - Parameters:
  ///   - debounce: quiet time after the last slider change before saving.
  ///   - sleep: waits for the debounce; replaced in tests.
  public init(
    controller: any FocusControlling, state: MenuBarState = MenuBarState(),
    debounce: Duration = MenuBarViewModel.defaultDebounce,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.controller = controller
    self.state = state
    self.debounce = debounce
    self.sleep = sleep
    rememberDisplays(of: state.configuration.scope)
  }

  /// Takes new state from the app. While a slider change is not saved yet, the
  /// local effects stay, so a late round trip cannot move the slider back.
  public func apply(_ newState: MenuBarState) {
    var newState = newState
    if let pendingEffects { newState.configuration.effects = pendingEffects }
    state = newState
    rememberDisplays(of: newState.configuration.scope)
  }

  // MARK: Main switch and scope

  public var isEnabled: Bool { state.configuration.isEnabled }

  public func setEnabled(_ isEnabled: Bool) {
    state.configuration.isEnabled = isEnabled
    controller.setEnabled(isEnabled)
  }

  public var scopeChoice: ScopeChoice { ScopeChoice(state.configuration.scope) }

  /// Switching to the display scope restores the last display selection.
  public func selectScope(_ choice: ScopeChoice) {
    let scope: EffectScope =
      switch choice {
      case .allDisplays: .allDisplays
      case .displays: .displays(lastDisplaySelection)
      case .regions: .regions
      }
    state.configuration.scope = scope
    controller.setScope(scope)
  }

  /// Names the first step when nothing is selected yet.
  public var selectionButtonTitle: String? {
    switch state.configuration.scope {
    case .allDisplays: nil
    case .displays: scopeChoice.selectionButtonTitle
    case .regions:
      state.configuration.regions.isEmpty ? "Create Regions…" : scopeChoice.selectionButtonTitle
    }
  }

  /// True when the switch is on and at least one connected target can show the effect.
  public var isEffective: Bool {
    isEnabled && missingTargetText == nil
  }

  /// Second line of the header: on, off, or why nothing is blurred although on.
  public var statusText: String {
    guard isEnabled else { return "Off" }
    return missingTargetText ?? "On"
  }

  private var missingTargetText: String? {
    let connected = Set(state.displays.map(\.id))
    switch state.configuration.scope {
    case .allDisplays:
      return nil
    case .displays(let selected):
      if selected.isEmpty { return "No display selected" }
      return selected.isDisjoint(with: connected) ? "Selected displays not connected" : nil
    case .regions:
      let enabled = state.configuration.regions.filter(\.isEnabled)
      if enabled.isEmpty { return "No active region" }
      return enabled.contains { connected.contains($0.displayID) }
        ? nil : "Regions paused: display not connected"
    }
  }

  public func startScopeSelection() {
    guard let mode = scopeChoice.selectionMode else { return }
    controller.startSelection(mode)
  }

  public func startWindowSelection() {
    controller.startSelection(.windows)
  }

  /// "All Displays", "2 displays", "3 regions, 1 paused".
  /// Paused means the display of an enabled region or selection is not connected.
  public var scopeSummary: String {
    switch state.configuration.scope {
    case .allDisplays:
      return "All Displays"
    case .displays(let selected):
      guard !selected.isEmpty else { return "No display selected" }
      let connected = Set(state.displays.map(\.id))
      let paused = selected.subtracting(connected).count
      var text = Self.count(selected.count, "display", "displays")
      if paused > 0 { text += ", \(paused) paused" }
      return text
    case .regions:
      let regions = state.configuration.regions
      guard !regions.isEmpty else { return "No regions" }
      let connected = Set(state.displays.map(\.id))
      let paused = regions.filter { $0.isEnabled && !connected.contains($0.displayID) }.count
      let disabled = regions.filter { !$0.isEnabled }.count
      var text = Self.count(regions.count, "region", "regions")
      if paused > 0 { text += ", \(paused) paused" }
      if disabled > 0 { text += ", \(disabled) disabled" }
      return text
    }
  }

  // MARK: Effects

  public var effects: EffectSettings { state.configuration.effects }

  public var blurText: String { EffectFormatting.percent(effects.blur) }
  public var backgroundBrightnessText: String {
    EffectFormatting.percent(effects.backgroundBrightness)
  }
  public var transitionDurationText: String {
    EffectFormatting.duration(effects.transitionDuration)
  }

  public var usesFallbackBlur: Bool { state.usesFallbackBlur }

  /// Values outside the bounds are clamped by `EffectSettings`.
  public func setBlur(_ value: Double) {
    change(
      EffectSettings(
        blur: value, backgroundBrightness: effects.backgroundBrightness,
        transitionDuration: effects.transitionDuration))
  }

  public func setBackgroundBrightness(_ value: Double) {
    change(
      EffectSettings(
        blur: effects.blur, backgroundBrightness: value,
        transitionDuration: effects.transitionDuration))
  }

  public func setTransitionDuration(_ seconds: Double) {
    change(
      EffectSettings(
        blur: effects.blur, backgroundBrightness: effects.backgroundBrightness,
        transitionDuration: seconds))
  }

  public var hasPendingCommit: Bool { pendingEffects != nil }

  /// Saves a pending change now. Call when the popover closes, so nothing is lost.
  public func flushPendingCommit() {
    commitTask?.cancel()
    commitTask = nil
    guard let effects = pendingEffects else { return }
    pendingEffects = nil
    controller.commitEffects(effects)
  }

  private func change(_ newEffects: EffectSettings) {
    guard newEffects != effects else { return }
    state.configuration.effects = newEffects
    pendingEffects = newEffects
    controller.previewEffects(newEffects)
    commitTask?.cancel()
    commitTask = Task { [weak self, sleep = self.sleep, debounce = self.debounce] in
      do { try await sleep(debounce) } catch { return }
      guard !Task.isCancelled else { return }
      self?.flushPendingCommit()
    }
  }

  // MARK: Exceptions

  public func removeException(_ exception: MenuBarException) {
    state.exceptions.removeAll { $0.reference == exception.reference }
    controller.removeException(exception.reference)
  }

  // MARK: Icon, app

  public var statusIcon: StatusIcon {
    StatusIcon.make(isEnabled: isEnabled)
  }

  public func quit() {
    flushPendingCommit()
    controller.quit()
  }

  // MARK: Helpers

  private func rememberDisplays(of scope: EffectScope) {
    if case .displays(let selected) = scope { lastDisplaySelection = selected }
  }

  private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
    "\(value) \(value == 1 ? singular : plural)"
  }
}
