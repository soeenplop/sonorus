import Foundation

public enum SelectionMode: Equatable, Sendable {
  case windows
  case displays
  case regions
}

/// Detached edit transaction. Services never mutate live settings before commit.
public struct SelectionDraft: Equatable, Sendable {
  public var windows: Set<WindowReference>
  public var displays: Set<DisplayID>
  public var regions: [FocusRegion]

  public init(
    windows: Set<WindowReference> = [], displays: Set<DisplayID> = [], regions: [FocusRegion] = []
  ) {
    self.windows = windows
    self.displays = displays
    self.regions = regions
  }
}

public struct SelectionRequest: Equatable, Sendable {
  public let mode: SelectionMode
  public let desktop: DesktopSnapshot
  public let draft: SelectionDraft

  public init(mode: SelectionMode, desktop: DesktopSnapshot, draft: SelectionDraft) {
    self.mode = mode
    self.desktop = desktop
    self.draft = draft
  }
}

public enum SelectionOutcome: Equatable, Sendable {
  /// `mode` is the mode the pass ended in; the draft keeps edits of every mode.
  case confirmed(SelectionDraft, mode: SelectionMode)
  case cancelled
}

/// Implementations own their event lifecycle and release observers on stop.
@MainActor
public protocol DesktopProviding: AnyObject {
  var currentSnapshot: DesktopSnapshot? { get }
  func start() async throws
  func stop()
  func updates() -> AsyncStream<DesktopSnapshot>
  func beginFocusFreeze()
  func endFocusFreeze() async
}

@MainActor
public protocol DisplayProviding: AnyObject {
  func currentDisplays() -> [DisplaySnapshot]
}

public protocol ConfigurationStoring: Sendable {
  func load() async throws -> FocusConfiguration
  func save(_ configuration: FocusConfiguration) async throws
}

public protocol EffectResolving: Sendable {
  func resolve(desktop: DesktopSnapshot, session: FocusSession) -> RenderScene
}

/// render must remove effects for empty or absent masks; stop removes every
/// overlay. Implementations may not activate themselves or consume user input.
///
/// With an anchor, surfaces are ordered directly below `anchor.window` and show
/// the `anchored` masks. Afterwards the renderer verifies the live order; if
/// anything other than `anchor.group` lies above the surfaces, or anchoring is
/// impossible, it shows the `overlay` masks at normal level + 1 instead.
/// Ordering and tile changes are applied in one CATransaction/commit so that no
/// intermediate state is visible.
@MainActor
public protocol OverlayRendering: AnyObject {
  func render(_ scene: RenderScene, desktop: DesktopSnapshot) async throws
  func stop()
}

@MainActor
public protocol SelectionPresenting: AnyObject {
  func select(_ request: SelectionRequest) async -> SelectionOutcome
  func cancel()
}

extension FocusSession {
  /// Applies a confirmed selection pass that started from `original` in
  /// `startMode` and ended in `endMode`. Edits of every mode are kept: the
  /// exceptions always, regions when they changed. The scope follows the last
  /// display or region mode used, but never switches to an empty selection.
  public mutating func apply(
    _ draft: SelectionDraft, original: SelectionDraft,
    startMode: SelectionMode, endMode: SelectionMode
  ) {
    exceptions = draft.windows
    if draft.regions != original.regions { configuration.regions = draft.regions }

    let scopeMode =
      [endMode, startMode].first { $0 != .windows }
      ?? (draft.displays != original.displays
        ? .displays : draft.regions != original.regions ? .regions : nil)
    switch scopeMode {
    case .displays:
      if case .displays = configuration.scope {
        configuration.scope = .displays(draft.displays)
      } else if !draft.displays.isEmpty {
        configuration.scope = .displays(draft.displays)
      }
    case .regions:
      if configuration.scope == .regions || !draft.regions.isEmpty {
        configuration.scope = .regions
      }
    case .windows, nil:
      break
    }
  }
}
