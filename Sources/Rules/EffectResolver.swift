import Contracts
import Geometry

/// Pure effect rules from PLAN 3.2:
///
///     effect area = selected scope − visible parts of sharp windows
///
/// Inactive windows and the uncovered desktop background (wallpaper, desktop
/// icons, widgets) inside the scope receive the effect. Sharp windows are the
/// protected normal app windows (focused, associated, runtime exceptions).
/// Only normal-level app windows take part: system UI and higher levels (Dock,
/// menu bar, floating panels) draw above the effect surfaces by themselves,
/// lower levels belong to the blurred background. Windows are walked front to
/// back in one pass and every normal window occludes what lies behind it, so
/// only the visible part of a sharp window is cut out: an exception never
/// reveals content of a window in front of it. Wallpaper coverage needs no
/// window in the snapshot.
///
/// The leading run of normal windows (level 0) that are all protected forms the
/// front group. If it contains the focused window, the scene carries a
/// `RenderAnchor` and two masks per display: `overlay` cuts out every sharp
/// window, `anchored` keeps the group's area because the group is drawn above
/// surfaces ordered below the anchor. In the common case `anchored` is the
/// whole scope of a display. Without an anchor both masks are equal and only
/// `overlay` is valid.
///
/// All input geometry is snapped to `ScreenRect.exactGrid` first so that the
/// emitted rectangles are strictly non-overlapping despite floating point.
///
/// The resolver fails closed: without an enabled configuration, an available
/// focus and a focused window that is on screen, every mask is empty and there
/// is no anchor. `.uncertain` focus (guessed from the window order) shows
/// the effect: Sonorus works without Accessibility (user decision). A
/// minimized focused window or one on another Space therefore pauses the effect.
public struct EffectResolver: EffectResolving {
  public init() {}

  public func resolve(desktop: DesktopSnapshot, session: FocusSession) -> RenderScene {
    let configuration = session.configuration
    let displays = Self.effectDisplays(in: desktop, scope: configuration.scope)
    let isActive = Self.isActive(desktop: desktop, configuration: configuration)
    let sharp =
      isActive
      ? Self.visibleSharpArea(desktop: desktop, exceptions: session.exceptions)
      : SharpArea(anchored: .empty, overlay: .empty, anchor: nil)
    let masks = displays.map { display in
      let scope =
        isActive
        ? Self.scopeArea(of: display, configuration: configuration).intersection(display.frame)
        : ScreenRegion.empty
      let overlay = scope.subtracting(sharp.overlay).coalesced().rectangles
      let anchored =
        sharp.anchor == nil
        ? overlay : scope.subtracting(sharp.anchored).coalesced().rectangles
      return DisplayEffectMask(
        placement: DisplayPlacement(
          runtimeID: display.runtimeID, displayID: display.id, frame: display.frame),
        anchored: anchored, overlay: overlay)
    }
    return RenderScene(
      revision: desktop.revision, masks: masks, effects: configuration.effects,
      anchor: sharp.anchor)
  }

  static func isActive(desktop: DesktopSnapshot, configuration: FocusConfiguration) -> Bool {
    guard configuration.isEnabled, desktop.focusConfidence != .unavailable,
      let focused = desktop.focusedWindow
    else { return false }
    return desktop.windows.contains { $0.reference == focused && $0.isOnScreen }
  }

  /// Displays with a usable frame that the scope may affect. Duplicate IDs are
  /// ambiguous: rules bound to a display (selected displays, regions) pause
  /// instead of guessing, while "all displays" needs no identity and still
  /// covers them; their placements stay distinct through `runtimeID`. Displays
  /// that violate the unique runtime ID contract are dropped entirely.
  static func effectDisplays(in desktop: DesktopSnapshot, scope: EffectScope)
    -> [DisplaySnapshot]
  {
    var counts: [DisplayID: Int] = [:]
    var runtimeCounts: [UInt32: Int] = [:]
    for display in desktop.displays {
      counts[display.id, default: 0] += 1
      runtimeCounts[display.runtimeID, default: 0] += 1
    }
    let allowsAmbiguous = scope == .allDisplays
    return desktop.displays.compactMap { display in
      guard allowsAmbiguous || counts[display.id] == 1, runtimeCounts[display.runtimeID] == 1,
        let frame = display.frame.snapped()
      else { return nil }
      return DisplaySnapshot(
        id: display.id, runtimeID: display.runtimeID, name: display.name, frame: frame,
        scale: display.scale)
    }
  }

  /// Area the selected mode allows on one display, already clipped to it.
  /// Regions of displays absent from the snapshot are never evaluated, which
  /// pauses them without moving them to another display.
  static func scopeArea(of display: DisplaySnapshot, configuration: FocusConfiguration)
    -> ScreenRegion
  {
    switch configuration.scope {
    case .allDisplays:
      return ScreenRegion(display.frame)
    case .displays(let selected):
      return selected.contains(display.id) ? ScreenRegion(display.frame) : .empty
    case .regions:
      let rects = configuration.regions
        .filter { $0.isEnabled && $0.displayID == display.id }
        .compactMap { DisplayGeometry.screenRect(for: $0.rect, on: display)?.snapped() }
      return ScreenRegion(unioning: rects)
    }
  }

  struct SharpArea: Equatable {
    var anchored: ScreenRegion
    var overlay: ScreenRegion
    var anchor: RenderAnchor?
  }

  /// Visible parts of windows that must stay sharp, for overlay surfaces and,
  /// without the front group, for anchored surfaces. The group is decided
  /// while walking, because it is a leading run of normal windows.
  static func visibleSharpArea(desktop: DesktopSnapshot, exceptions: Set<WindowReference>)
    -> SharpArea
  {
    var protected = desktop.associatedWindows.union(exceptions)
    if let focused = desktop.focusedWindow { protected.insert(focused) }

    var group: [WindowReference] = []
    var inFrontGroup = true
    var occluded = ScreenRegion.empty
    var anchoredOccluded = ScreenRegion.empty
    var anchored = ScreenRegion.empty
    var overlay = ScreenRegion.empty
    // Only normal app windows shape the masks. Higher levels (Dock, menu bar,
    // floating panels) already draw above the effect surfaces; lower levels
    // (wallpaper, desktop icons, widgets) belong to the blurred background.
    // Cutting holes for either produced hard-edged, smeared gaps (user test).
    for window in desktop.windows
    where window.isOnScreen && window.level == 0 && !window.isSystemUI {
      guard let frame = window.frame.snapped() else { continue }
      let isGroupMember = inFrontGroup && protected.contains(window.reference)
      inFrontGroup = isGroupMember
      if isGroupMember { group.append(window.reference) }
      if protected.contains(window.reference) {
        let visible = ScreenRegion(frame).subtracting(occluded)
        overlay.formUnion(visible)
        if !isGroupMember {
          anchored.formUnion(ScreenRegion(frame).subtracting(anchoredOccluded))
        }
      }
      occluded.formUnion(frame)
      // The anchor group draws above anchored tiles. Ignore it for visibility
      // there, but retain every foreign occluder so exceptions cannot cut holes
      // through inactive windows in front of them.
      if !isGroupMember { anchoredOccluded.formUnion(frame) }
    }

    guard let focused = desktop.focusedWindow, group.contains(focused), let rear = group.last
    else { return SharpArea(anchored: overlay, overlay: overlay, anchor: nil) }
    return SharpArea(
      anchored: anchored, overlay: overlay,
      anchor: RenderAnchor(window: rear, group: Set(group)))
  }
}
