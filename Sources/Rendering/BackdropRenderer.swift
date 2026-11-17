import Contracts
import CoreGraphics
import Observation

public enum RenderingError: Error, Equatable {
  /// No effect surface could be created for at least one display.
  case surfaceUnavailable
  /// Neither the snapshot nor the system names the primary display.
  case unknownPrimaryDisplay
}

/// Production renderer (M0 variant D): per display two full-display backdrop
/// surfaces. The active one sits directly below `RenderScene.anchor.window`
/// with the `anchored` mask, verified against the live window order; without
/// an anchor, or when anything outside the anchor group lies above it, it
/// shows the `overlay` mask above all normal windows instead. A changed
/// position cross-blurs into the spare surface, so content behind both stays
/// constant while the windows in between blur in from zero.
@MainActor
@Observable
public final class BackdropRenderer: OverlayRendering {
  /// True when the private backdrop blur is missing and a material without
  /// adjustable radius stands in for it.
  public private(set) var isUsingFallbackBlur: Bool

  private let factory: any EffectSurfaceMaking
  private let windowList: any WindowListReading
  private let scheduler: any TransitionScheduling
  private let accessibility: any AccessibilityDisplayOptions
  @ObservationIgnored private var displays: [UInt32: DisplayEffect] = [:]
  @ObservationIgnored private var latest: (scene: RenderScene, desktop: DesktopSnapshot)?
  @ObservationIgnored private var retry: (any ScheduledAction)?

  public convenience init() {
    self.init(
      factory: PanelSurfaceFactory(), windowList: SystemWindowList(),
      scheduler: MainQueueScheduler(), accessibility: WorkspaceAccessibility())
  }

  init(
    factory: any EffectSurfaceMaking, windowList: any WindowListReading,
    scheduler: any TransitionScheduling, accessibility: any AccessibilityDisplayOptions
  ) {
    self.factory = factory
    self.windowList = windowList
    self.scheduler = scheduler
    self.accessibility = accessibility
    isUsingFallbackBlur = factory.usesFallbackBlur
  }

  public func render(_ scene: RenderScene, desktop: DesktopSnapshot) async throws {
    try renderNow(scene, desktop: desktop)
  }

  private func renderNow(_ scene: RenderScene, desktop: DesktopSnapshot) throws {
    latest = (scene, desktop)
    retry?.cancel()
    retry = nil
    let present = Set(scene.masks.map(\.placement.runtimeID))
    for (id, display) in displays where !present.contains(id) {
      remove(display)
      displays[id] = nil
    }
    guard
      let primaryHeight = RenderGeometry.primaryDisplayHeight(in: desktop.displays)
        ?? windowList.primaryDisplayHeight
    else {
      removeAll()
      throw RenderingError.unknownPrimaryDisplay
    }

    let appearance = EffectAppearance(scene.effects)
    let values = appearance.values
    let duration = accessibility.reduceMotion ? 0 : appearance.transitionDuration
    let order = scene.anchor.map { AnchorOrder($0, ownProcessID: windowList.ownProcessID) }
    let live = order == nil ? [] : windowList.frontToBackWindows()
    let now = scheduler.now
    var ordered: [(DisplayEffect, DisplayEffectMask)] = []
    var isMissingSurface = false
    var isWaiting = false
    var seen = Set<UInt32>()

    factory.performAtomically {
      for mask in scene.masks where seen.insert(mask.placement.runtimeID).inserted {
        let scale = desktop.displays.first { $0.runtimeID == mask.placement.runtimeID }?.scale
        guard
          let display = prepareDisplay(
            mask.placement, scale: scale ?? 2, primaryHeight: primaryHeight)
        else {
          isMissingSurface = true
          continue
        }
        let target = Self.target(
          for: mask, order: order, live: live, blockedAnchor: display.blockedAnchor(at: now))
        if display.defersOverlay(target, at: now) {
          isWaiting = true
          continue
        }
        if apply(target, to: display, values: values, duration: duration, order: order, live: live)
        {
          ordered.append((display, mask))
        }
      }
    }

    // The WindowServer may refuse or alter a relative order; check the result.
    if let order, !ordered.isEmpty {
      let fresh = windowList.frontToBackWindows()
      factory.performAtomically {
        for (display, mask) in ordered {
          guard
            !order.isDirectlyBelow(
              surface: display.active.windowID, on: mask.placement.frame, in: fresh)
          else {
            display.orderFailure = nil
            continue
          }
          // The window list often reports a new order a frame late; only a
          // failure that persists for the grace period demotes to overlay.
          guard let failure = display.orderFailure, failure.window == order.window else {
            display.orderFailure = (order.window, now)
            isWaiting = true
            continue
          }
          guard now - failure.since >= Self.overlayGrace else {
            isWaiting = true
            continue
          }
          display.orderFailure = nil
          display.anchorFailure = (order.window, now)
          demote(display, overlay: mask, duration: duration)
        }
      }
    }
    if isWaiting { scheduleRetry() }
    if isMissingSurface { throw RenderingError.surfaceUnavailable }
  }

  /// Re-renders the latest scene after the grace period, in case no new
  /// snapshot arrives while a display waits for its anchor.
  private func scheduleRetry() {
    retry = scheduler.schedule(after: Self.overlayGrace) { [weak self] in
      guard let self, let latest = self.latest else { return }
      self.retry = nil
      try? self.renderNow(latest.scene, desktop: latest.desktop)
    }
  }

  /// One line per display for diagnostics: placement, position and mask.
  public var debugSummary: String {
    displays.sorted { $0.key < $1.key }.map { id, display in
      let position: String
      switch display.position {
      case .anchored(let window)?: position = "below #\(window)"
      case .overlay?: position = "OVERLAY"
      case nil: position = "hidden"
      }
      let mask: String
      switch display.mask {
      case .full: mask = "full"
      case .rects(let rects): mask = "\(rects.count) rect(s)"
      }
      let transition = display.transition.map { _ in " transition" } ?? ""
      return "display \(id): \(position) mask=\(mask)\(transition)"
    }.joined(separator: " | ")
  }

  public func stop() {
    retry?.cancel()
    retry = nil
    latest = nil
    removeAll()
  }

  // MARK: Planning

  struct Target: Equatable {
    let position: SurfacePosition
    let mask: SurfaceMask
  }

  /// After a failed verification, anchoring below the same window waits this
  /// long, so a persistently failing order does not restart transitions.
  static let anchorRetryInterval = 0.5

  /// Right after a focus switch the WindowServer list may still show the old
  /// order. An anchored display keeps its placement this long before falling
  /// back to the overlay, which would cut rectangular holes and cross-fade
  /// twice (user test of the integrated app vs. the accepted prototype).
  static let overlayGrace = 0.25

  static func target(
    for mask: DisplayEffectMask, order: AnchorOrder?, live: [LiveWindow],
    blockedAnchor: UInt32? = nil
  ) -> Target {
    let frame = mask.placement.frame
    if let order, order.window != blockedAnchor, order.allowsAnchoring(on: frame, in: live) {
      return Target(
        position: .anchored(below: order.window),
        mask: RenderGeometry.mask(for: mask.anchored, in: frame))
    }
    return Target(position: .overlay, mask: RenderGeometry.mask(for: mask.overlay, in: frame))
  }

  // MARK: Applying

  private func prepareDisplay(_ placement: DisplayPlacement, scale: Double, primaryHeight: Double)
    -> DisplayEffect?
  {
    let frame = RenderGeometry.appKitFrame(
      of: placement.frame, primaryDisplayHeight: primaryHeight)
    if let display = displays[placement.runtimeID] {
      display.placement = placement.frame
      if display.frame != frame || display.scale != scale {
        display.active.setFrame(frame, scale: scale)
        display.spare.setFrame(frame, scale: scale)
        display.frame = frame
        display.scale = scale
      }
      return display
    }
    guard let first = factory.makeSurface(frame: frame, scale: scale) else { return nil }
    guard let second = factory.makeSurface(frame: frame, scale: scale) else {
      first.close()
      return nil
    }
    let display = DisplayEffect(
      placement: placement.frame, frame: frame, scale: scale, active: first, spare: second)
    displays[placement.runtimeID] = display
    return display
  }

  /// Returns whether the active surface was ordered below the anchor and
  /// needs verification against the live order.
  private func apply(
    _ target: Target, to display: DisplayEffect, values: SurfaceValues, duration: Double,
    order: AnchorOrder?, live: [LiveWindow]
  ) -> Bool {
    guard !target.mask.isEmpty else {
      fadeOut(display, duration: duration)
      return false
    }
    guard display.isShowing else {
      show(display, target, values: values, duration: duration)
      return target.position.isAnchored
    }
    guard display.position == target.position else {
      if duration > 0 {
        cross(display, to: target, values: values, duration: duration)
      } else {
        finishTransition(display)
        place(display.active, at: target.position)
        display.active.setMask(target.mask)
        display.active.setValues(values)
        display.position = target.position
        display.mask = target.mask
        display.target = values
      }
      return target.position.isAnchored
    }
    var reordered = false
    if case .anchored(let window) = target.position, let order,
      !order.isDirectlyBelow(surface: display.active.windowID, on: display.placement, in: live)
    {
      display.active.order(below: window)
      reordered = true
    }
    if display.mask != target.mask {
      display.active.setMask(target.mask)
      display.mask = target.mask
    }
    if display.target != values {
      finishTransition(display)
      display.active.setValues(values)
      display.target = values
    }
    return reordered
  }

  private func show(
    _ display: DisplayEffect, _ target: Target, values: SurfaceValues, duration: Double
  ) {
    let current = display.currentValues(at: scheduler.now)
    discardTransition(display)
    place(display.active, at: target.position)
    display.active.setMask(target.mask)
    display.position = target.position
    display.mask = target.mask
    display.target = values
    if duration > 0, current != values {
      startFade(display, from: current, to: values, duration: duration, hides: false)
    } else {
      display.active.setValues(values)
    }
  }

  private func fadeOut(_ display: DisplayEffect, duration: Double) {
    guard display.isShowing else { return }
    let current = display.currentValues(at: scheduler.now)
    if case .cross = display.transition {
      finishTransition(display)
    } else {
      discardTransition(display)
    }
    guard duration > 0, current != .zero else {
      hide(display)
      return
    }
    startFade(display, from: current, to: .zero, duration: duration, hides: true)
  }

  private func cross(
    _ display: DisplayEffect, to target: Target, values: SurfaceValues, duration: Double
  ) {
    finishTransition(display)
    let incoming = display.spare
    let outgoing = display.active
    incoming.setValues(.zero)
    incoming.setMask(target.mask)
    place(incoming, at: target.position)
    incoming.animate(.crossIn(to: values, duration: duration))
    outgoing.animate(.crossOut(from: values, duration: duration))
    display.active = incoming
    display.spare = outgoing
    display.position = target.position
    display.mask = target.mask
    display.target = values
    display.transition = .cross(schedule(display, after: duration))
  }

  /// The anchored order failed verification: lift the active surface above
  /// all normal windows with the overlay mask.
  private func demote(_ display: DisplayEffect, overlay: DisplayEffectMask, duration: Double) {
    let mask = RenderGeometry.mask(for: overlay.overlay, in: overlay.placement.frame)
    guard !mask.isEmpty else {
      fadeOut(display, duration: duration)
      return
    }
    display.active.orderAboveNormalWindows()
    display.active.setMask(mask)
    display.position = .overlay
    display.mask = mask
  }

  private func startFade(
    _ display: DisplayEffect, from start: SurfaceValues, to end: SurfaceValues, duration: Double,
    hides: Bool
  ) {
    display.active.animate(.fade(from: start, to: end, duration: duration))
    let fade = DisplayEffect.Fade(
      from: start, to: end, start: scheduler.now, duration: duration, hides: hides)
    display.transition = .fade(fade, schedule(display, after: duration))
  }

  private func schedule(_ display: DisplayEffect, after duration: Double) -> any ScheduledAction {
    display.generation += 1
    let generation = display.generation
    return scheduler.schedule(after: duration) { [weak self, weak display] in
      guard let self, let display, display.generation == generation else { return }
      self.factory.performAtomically { self.finishTransition(display) }
    }
  }

  /// Ends a running transition at its final state.
  private func finishTransition(_ display: DisplayEffect) {
    guard let transition = display.transition else { return }
    discardTransition(display)
    switch transition {
    case .cross:
      display.active.setValues(display.target)
      display.spare.setValues(.zero)
      display.spare.hide()
    case .fade(let fade, _):
      if fade.hides {
        hide(display)
      } else {
        display.active.setValues(fade.to)
      }
    }
  }

  /// Forgets a running transition without touching the surfaces.
  private func discardTransition(_ display: DisplayEffect) {
    display.transition?.action.cancel()
    display.transition = nil
    display.generation += 1
  }

  private func hide(_ display: DisplayEffect) {
    discardTransition(display)
    for surface in [display.active, display.spare] {
      surface.setValues(.zero)
      surface.hide()
    }
    display.position = nil
    display.mask = .empty
  }

  private func remove(_ display: DisplayEffect) {
    discardTransition(display)
    display.active.close()
    display.spare.close()
  }

  private func removeAll() {
    for display in displays.values { remove(display) }
    displays.removeAll()
  }

  private func place(_ surface: any EffectSurface, at position: SurfacePosition) {
    switch position {
    case .anchored(let window): surface.order(below: window)
    case .overlay: surface.orderAboveNormalWindows()
    }
  }
}

/// Surfaces and transition state of one display placement.
@MainActor
final class DisplayEffect {
  struct Fade {
    let from: SurfaceValues
    let to: SurfaceValues
    let start: Double
    let duration: Double
    /// Fade-out: the surfaces leave the screen at the end.
    let hides: Bool
  }

  enum Transition {
    case cross(any ScheduledAction)
    case fade(Fade, any ScheduledAction)

    var action: any ScheduledAction {
      switch self {
      case .cross(let action), .fade(_, let action): action
      }
    }
  }

  /// Global Quartz frame of the placement.
  var placement: ScreenRect
  /// AppKit frame of both surfaces.
  var frame: CGRect
  var scale: Double
  var active: any EffectSurface
  var spare: any EffectSurface
  /// Position of the active surface; nil while hidden.
  var position: SurfacePosition?
  var mask = SurfaceMask.empty
  /// Resting values of the active surface while shown.
  var target = SurfaceValues.zero
  var transition: Transition?
  var generation = 0
  /// Anchor window whose order was demoted after failing verification, and when.
  var anchorFailure: (window: UInt32, time: Double)?
  /// First failed verification below an anchor that is not yet demoted.
  var orderFailure: (window: UInt32, since: Double)?
  /// Since when an anchored display has been asked to fall back to overlay.
  var overlaySince: Double?

  init(
    placement: ScreenRect, frame: CGRect, scale: Double, active: any EffectSurface,
    spare: any EffectSurface
  ) {
    self.placement = placement
    self.frame = frame
    self.scale = scale
    self.active = active
    self.spare = spare
  }

  /// Keeps an anchored, visible display in place while an overlay target
  /// lasts shorter than `BackdropRenderer.overlayGrace`.
  func defersOverlay(_ target: BackdropRenderer.Target, at now: Double) -> Bool {
    guard target.position == .overlay, !target.mask.isEmpty, isShowing,
      position?.isAnchored == true
    else {
      overlaySince = nil
      return false
    }
    let since = overlaySince ?? now
    overlaySince = since
    return now - since < BackdropRenderer.overlayGrace
  }

  func blockedAnchor(at now: Double) -> UInt32? {
    guard let anchorFailure, now - anchorFailure.time < BackdropRenderer.anchorRetryInterval
    else { return nil }
    return anchorFailure.window
  }

  /// Shown and not fading out.
  var isShowing: Bool {
    guard position != nil else { return false }
    if case .fade(let fade, _) = transition, fade.hides { return false }
    return true
  }

  /// Values the active surface shows right now, sampled analytically.
  func currentValues(at now: Double) -> SurfaceValues {
    switch transition {
    case .none: position == nil ? .zero : target
    case .cross: target
    case .fade(let fade, _):
      fade.from.interpolated(
        to: fade.to, progress: CrossBlur.eased((now - fade.start) / fade.duration))
    }
  }
}
