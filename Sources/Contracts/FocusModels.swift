import Foundation

public enum EffectScope: Codable, Equatable, Sendable {
  case allDisplays
  case displays(Set<DisplayID>)
  case regions
}

public struct FocusRegion: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var displayID: DisplayID
  public var rect: NormalizedRect
  public var isEnabled: Bool

  public init(
    id: UUID = UUID(), displayID: DisplayID, rect: NormalizedRect, isEnabled: Bool = true
  ) {
    self.id = id
    self.displayID = displayID
    self.rect = rect
    self.isEnabled = isEnabled
  }
}

/// Immutable validated effect parameters; persisted input uses the same bounds
/// as the UI. Brightness is image brightness, never physical display brightness.
public struct EffectSettings: Codable, Equatable, Sendable {
  public let blur: Double
  public let backgroundBrightness: Double
  public let transitionDuration: Double

  public init(
    blur: Double = 0.5, backgroundBrightness: Double = 0.7, transitionDuration: Double = 0.75
  ) {
    self.blur = Self.bounded(blur, maximum: 1, fallback: 0.5)
    self.backgroundBrightness = Self.bounded(backgroundBrightness, maximum: 1, fallback: 0.7)
    self.transitionDuration = Self.bounded(transitionDuration, maximum: 1.5, fallback: 0.75)
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      blur: try values.decode(Double.self, forKey: .blur),
      backgroundBrightness: try values.decode(Double.self, forKey: .backgroundBrightness),
      transitionDuration: try values.decode(Double.self, forKey: .transitionDuration))
  }

  private static func bounded(_ value: Double, maximum: Double, fallback: Double) -> Double {
    value.isFinite ? min(maximum, max(0, value)) : fallback
  }
}

/// Persistable preferences. Runtime window exceptions are deliberately separate.
public struct FocusConfiguration: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var scope: EffectScope
  public var regions: [FocusRegion]
  public var effects: EffectSettings

  public init(
    isEnabled: Bool = false, scope: EffectScope = .allDisplays,
    regions: [FocusRegion] = [], effects: EffectSettings = EffectSettings()
  ) {
    self.isEnabled = isEnabled
    self.scope = scope
    self.regions = regions
    self.effects = effects
  }
}

public struct FocusSession: Equatable, Sendable {
  public var configuration: FocusConfiguration
  public var exceptions: Set<WindowReference>

  public init(
    configuration: FocusConfiguration = FocusConfiguration(),
    exceptions: Set<WindowReference> = []
  ) {
    self.configuration = configuration
    self.exceptions = exceptions
  }
}

/// One display as it is placed in a single snapshot. `runtimeID` is unique
/// within that snapshot and distinguishes displays that share an ambiguous
/// `DisplayID`; it is transient and must never be persisted.
public struct DisplayPlacement: Hashable, Sendable {
  public let runtimeID: UInt32
  public let displayID: DisplayID
  public let frame: ScreenRect

  public init(runtimeID: UInt32, displayID: DisplayID, frame: ScreenRect) {
    self.runtimeID = runtimeID
    self.displayID = displayID
    self.frame = frame
  }
}

/// Positive, global-point mask pieces for one display placement, clipped to
/// its frame and free of double coverage. Shape fidelity is an M0 decision.
///
/// - `overlay`: every on-screen window occludes. Valid for surfaces above all
///   normal windows.
/// - `anchored`: windows of the anchor group do not occlude. Valid only while
///   the surfaces sit directly below `RenderScene.anchor.window`, so the group
///   draws over them. Always covers at least `overlay`.
public struct DisplayEffectMask: Equatable, Sendable {
  public let placement: DisplayPlacement
  public let anchored: [ScreenRect]
  public let overlay: [ScreenRect]

  public init(placement: DisplayPlacement, anchored: [ScreenRect], overlay: [ScreenRect]) {
    self.placement = placement
    self.anchored = anchored
    self.overlay = overlay
  }
}

/// Protected front group: the focused window, its associated windows and
/// exceptions that are contiguous at the front of the normal windows.
/// `window` is the rearmost member; effect surfaces are ordered directly below
/// it. References are snapshot facts, not a guarantee about the live order.
public struct RenderAnchor: Equatable, Sendable {
  public let window: WindowReference
  public let group: Set<WindowReference>

  public init(window: WindowReference, group: Set<WindowReference>) {
    self.window = window
    self.group = group
  }
}

/// Placements absent from `masks` must show no effect. Without an anchor only
/// the overlay masks are valid. The scene does not prescribe the blur source.
public struct RenderScene: Equatable, Sendable {
  public let revision: UInt64
  public let masks: [DisplayEffectMask]
  public let effects: EffectSettings
  public let anchor: RenderAnchor?

  public init(
    revision: UInt64, masks: [DisplayEffectMask], effects: EffectSettings,
    anchor: RenderAnchor? = nil
  ) {
    self.revision = revision
    self.masks = masks
    self.effects = effects
    self.anchor = anchor
  }
}
