import AppKit
import SpikeKit

// Variant C (hypothesis): a normal-level effect panel per display ordered
// directly below the focused window of another app with
// NSWindow.order(.below, relativeTo: foreignWindowNumber). Everything below
// the panel is blurred; the focused window stays sharp without a mask.
// https://developer.apple.com/documentation/appkit/nswindow/order(_:relativeto:)
//
// The panel is ordered below the focus *group* (focused window + same-app
// sheets/dialogs in front of it, but no parent inferred from containment; see
// `Anchoring`). If a foreign window is in front of the group, the panel falls
// back to overlay placement (level normal + 1, Variant A semantics).
//
// --mask tiles (hybrid C+A): effect tiles cover only the visible parts of
// inactive windows below the panel, so the desktop stays sharp and exceptions
// can be punched out. The tiles do not depend on the focused window's geometry.
// --mask layer: like tiles, but one effect view per display masked by a
// CAShapeLayer path (rounded corners, no seams between adjacent pieces).
//
// On an active-Space change the effect is hidden until the order is verified
// on two consecutive checks.
//
// Usage: swift run VariantC [--duration 8] [--material hudWindow] [--alpha 1]
//   [--dim 0.3] [--follow] [--target 1234] [--mask full|tiles|layer]
//   [--mask-backend native|layer] [--menu-fade 0] [--transition 0.75] [--mask-on effect|host] [--corner-radius 26] [--poll 0.1]
//   [--except 123,456] [--titles] [--guard-settle 0.034] [--no-controls]
//
// Unless --no-controls is given, a menu bar icon adjusts blur (effect
// opacity), dim and material live (full and layer masks only).
//
// --blur window [--radius 24]: stepless WindowServer blur behind each panel
// via the undocumented SkyLight call (see `WindowBlur`); NSVisualEffectView is
// switched off and only a faint dim carries the mask. Open questions for the
// user: does the blur follow the mask (holes, transitions) or the whole panel?
// Observed: the whole panel rectangle; no rounded corners, no partial ramps.
//
// --blur backdrop [--radius 24]: stepless blur from the undocumented
// CABackdropLayer (see `BackdropBlur`). It is a layer, so vector masks,
// rounded corners and per-region radius ramps on focus switches apply.

let args = Args()
CGWin.showTitles = args.flag("titles")

@MainActor
final class VariantC {
  enum Placement: Equatable {
    case none
    case below(CGWindowID)
    case overlay
  }

  @MainActor final class Surface {
    let display: DisplayInfo
    let panel: OverlayPanel
    /// Quartz rectangle the panel covers (scope in full mode, else the display).
    let area: CGRect
    let tiles: TileSurface?
    let masked: MaskedEffectSurface?
    var transition: FocusTransitionSurface?
    var placement = Placement.none
    var failureCache = AnchorFailureCache()
    var plan: AnchorPlan?
    var verifiedChecks = 0
    /// Radius last applied with `WindowBlur`; nil until the first success.
    var appliedRadius: Int?
    /// Gradual blur-in of the outgoing focus in `--blur window` mode.
    var blurRamp: WindowBlurTransition?
    /// Focus the running or finished ramp belongs to.
    var rampedFocus: CGWindowID?
    /// Windows sharp above the panel right before a reorder (e.g. every window
    /// of an app raised by ⌘Tab); they retire with a transition, too.
    var raisedSharp: CGPath?

    init(
      display: DisplayInfo, panel: OverlayPanel, area: CGRect, tiles: TileSurface?,
      masked: MaskedEffectSurface?
    ) {
      self.display = display
      self.panel = panel
      self.area = area
      self.tiles = tiles
      self.masked = masked
    }
  }

  let runner: SpikeRunner
  let material = Materials.named(args.string("material", default: "hudWindow")) ?? .hudWindow
  let windowBlur = args.string("blur", default: "native") == "window"
  let backdropBlur = args.string("blur", default: "native") == "backdrop"
  /// Points of WindowServer or backdrop blur; adjustable live.
  var blurRadius = CGFloat(min(64, max(0, args.double("radius", default: 24))))
  static let maxRadius: CGFloat = 64
  /// Dim currently shown; the menu controls change it live.
  lazy var currentDim: CGFloat = dimAlpha
  var effectAlpha: CGFloat { windowBlur ? 0 : CGFloat(args.double("alpha", default: 1)) }
  /// In window-blur mode a faint dim keeps the masked area non-transparent,
  /// in case the WindowServer limits the blur to drawn pixels.
  var dimAlpha: CGFloat { max(CGFloat(args.double("dim", default: 0.3)), windowBlur ? 0.01 : 0) }
  /// macOS 27 app windows are rounder than 12 pt; a smaller rounding left a
  /// half-blurred rim in the corners of retiring windows (user observation).
  let cornerRadius = CGFloat(args.double("corner-radius", default: 26))
  let focusTracker = FocusTracker()
  let maskMode = args.string("mask", default: "full")
  // Vector masks are rasterized by the render server: ~4 ms per update
  // instead of ~55 ms for `maskImage`, and the user observed far less
  // flicker on focus switches. `--mask-backend native` keeps the comparison.
  let nativeMask = args.string("mask-backend", default: "layer") == "native"
  let transitionDuration = FocusTransition.duration(args.double("transition", default: 0.75))
  let follows = args.flag("follow")
  /// Seconds the guard mask needs on screen before a reorder; see `apply`.
  /// The WindowServer blur is not drawn through our mask, so waiting for the
  /// mask only delays the reorder (e.g. after ⌘Tab raised all app windows).
  var guardSettle: Double {
    min(0.1, max(0, args.double("guard-settle", default: windowBlur ? 0 : 0.034)))
  }
  let forcedTarget = args.string("target").flatMap(UInt32.init)
  /// Window ids or pids; `--except` is the older spelling.
  let exceptionValues = Set(
    (args.list("exception") + args.list("except")).compactMap { UInt32($0) })
  let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
  var surfaces: [Surface] = []
  var target: CGWin?
  var isEffectVisible = false
  /// Set while the effect is hidden after a Space change; counts verified checks.
  var spaceHiddenAt: DispatchTime?
  var pendingActivation: (pid: pid_t, name: String, start: DispatchTime)?
  /// Last focus identity change, from a poll or an activation notification.
  var focusChangedAt: DispatchTime?
  /// A display deferred its overlay fallback on the last check.
  var settling = false
  var fastTimer: Timer?
  var applies = Samples()
  var maskUpdates = Samples()
  var activationToVerified = Samples()
  var spaceRecovery = Samples()
  var driftChecks = 0
  var drifts = 0
  var overlayFallbacks = 0

  init(runner: SpikeRunner) { self.runner = runner }

  func start() {
    SpikeEnvironment.report()
    if backdropBlur {
      guard BackdropBlur.isAvailable, maskMode == "full" else {
        Log.info("--blur backdrop needs --mask full and the private CABackdropLayer/CAFilter")
        runner.finish(code: 69)
      }
      Log.info("blur backdrop: CABackdropLayer gaussianBlur (undocumented), radius=\(blurRadius)")
    }
    if windowBlur {
      guard WindowBlur.isAvailable else {
        Log.info("--blur window: private SkyLight blur symbols not found on this macOS")
        runner.finish(code: 69)
      }
      Log.info("blur backend: WindowServer radius (undocumented), radius=\(blurRadius)")
    }
    guard ["full", "tiles", "layer"].contains(maskMode) else {
      Log.info("unknown --mask \(maskMode); options: full, tiles, layer")
      runner.finish(code: 64)
    }
    for display in Displays.all() {
      // Full mode extends behind the menu bar. Complete the fade within its
      // strip so bright document chrome below it is not revealed as a halo.
      // System menu windows remain above our normal/normal+1 panels.
      let full = maskMode == "full"
      let frame = display.appKitFrame
      let area = display.quartzBounds
      let panel = OverlayPanel(appKitFrame: frame, level: .normal)
      if maskMode == "tiles" {
        let root = FlippedView(frame: CGRect(origin: .zero, size: frame.size))
        let tiles = TileSurface(
          display: display, root: root, material: material, alpha: effectAlpha,
          dimAlpha: dimAlpha)
        root.wantsLayer = true
        let fade = MenuFade(
          bounds: root.bounds, menuInset: display.menuBarInset,
          points: CGFloat(args.double("menu-fade", default: 0)),
          topInset: display.menuBarInset, flipped: true)
        if fade.height > 0 { root.layer?.mask = MaskedEffectSurface.gradient(fade) }
        panel.contentView = root
        surfaces.append(
          Surface(display: display, panel: panel, area: area, tiles: tiles, masked: nil))
      } else {
        let masked = MaskedEffectSurface(
          display: display, material: material, alpha: effectAlpha, dimAlpha: dimAlpha,
          maskOnHost: args.string("mask-on", default: "effect") == "host", size: frame.size,
          menuFade: CGFloat(args.double("menu-fade", default: 0)),
          menuTopInset: full ? 0 : display.menuBarInset, menuFadeWithinBar: full)
        masked.apply(path: nil)
        panel.contentView = masked.host
        surfaces.append(
          Surface(display: display, panel: panel, area: area, tiles: nil, masked: masked))
      }
      if full, let surface = surfaces.last, let masked = surface.masked {
        surface.transition = FocusTransitionSurface(
          surface: masked, duration: transitionDuration, material: material,
          alpha: effectAlpha, dimAlpha: dimAlpha,
          fade: MenuFade.insideMenuBar(
            bounds: masked.host.bounds, menuInset: display.menuBarInset,
            points: CGFloat(args.double("menu-fade", default: 0))), native: nativeMask)
      }
      if backdropBlur, let transition = surfaces.last?.transition,
        !transition.useBackdrop(radius: blurRadius)
      {
        Log.info(
          "backdrop blur unavailable for displayID=\(display.displayID); native effect stays")
      }
      if full && windowBlur, let surface = surfaces.last {
        let ramp = WindowBlurTransition(level: .normal)
        surface.blurRamp = ramp
        runner.track(ramp.panel)
      }
      panel.contentView?.isHidden = true
      runner.track(panel)
    }
    if let forcedTarget {
      target = WindowList.onScreen().first { $0.id == forcedTarget }
    }
    tick(reason: "initial")
    guard target != nil else {
      Log.info("no foreign focused window found; nothing to order against")
      runner.finish(code: 2)
    }
    report(label: "after initial order")
    Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
      MainActor.assumeIsolated { self.report(label: "0.4s after initial order") }
    }
    let poll = args.double("poll", default: maskMode == "full" ? 0.25 : 0.1)
    Timer.scheduledTimer(withTimeInterval: poll, repeats: true) { _ in
      MainActor.assumeIsolated { self.tick(reason: "poll") }
    }
    if !args.flag("no-controls") { installControls() }
    if follows { observeActivation() }
    observeSpaces()
    runner.onTeardown {
      self.fastTimer?.invalidate()
      for surface in self.surfaces {
        surface.blurRamp?.cancel()
        surface.transition?.cancel(reason: "teardown")
      }
      Log.observed("apply cost (mask + order for all panels + commit): \(self.applies.summary)")
      Log.observed("mask/tile update cost (without reorder): \(self.maskUpdates.summary)")
      if !self.activationToVerified.values.isEmpty {
        Log.observed(
          "activation -> verified order below a window of the activated app: "
            + self.activationToVerified.summary)
      }
      if !self.spaceRecovery.values.isEmpty {
        Log.observed("space change -> effect shown again: \(self.spaceRecovery.summary)")
      }
      Log.observed(
        "checks=\(self.driftChecks) drifts=\(self.drifts) overlay fallbacks=\(self.overlayFallbacks) "
          + "(drift = a normal window outside the focus group above the panel, or the group below it)"
      )
    }
  }

  var controls: EffectControls?

  func installControls() {
    let initial = EffectControls.Values(
      material: material,
      blur: windowBlur || backdropBlur ? blurRadius / Self.maxRadius : effectAlpha,
      dim: dimAlpha)
    let blurTitle: (CGFloat) -> String =
      windowBlur || backdropBlur
      ? { "Blur-Radius: \(Int(($0 * Self.maxRadius).rounded())) pt" }
      : { "Blur: \(Int(($0 * 100).rounded())) %" }
    controls = EffectControls(values: initial, blurTitle: blurTitle) { values in
      if self.backdropBlur {
        self.blurRadius = values.blur * Self.maxRadius
        self.currentDim = values.dim
        for surface in self.surfaces {
          surface.transition?.setAppearance(
            material: values.material, alpha: 0, dimAlpha: values.dim)
          surface.transition?.setBackdropRadius(self.blurRadius)
        }
        Log.info("appearance radius=\(Int(self.blurRadius.rounded())) dim=\(values.dim)")
        return
      }
      if self.windowBlur {
        self.blurRadius = values.blur * Self.maxRadius
        let dim = max(values.dim, 0.01)
        self.currentDim = dim
        for surface in self.surfaces {
          surface.transition?.setAppearance(material: values.material, alpha: 0, dimAlpha: dim)
          if surface.transition == nil {
            surface.masked?.setAppearance(material: values.material, alpha: 0, dimAlpha: dim)
          }
        }
        self.syncWindowBlur()
        Log.info("appearance radius=\(Int(self.blurRadius.rounded())) dim=\(dim)")
        return
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for surface in self.surfaces {
        if let transition = surface.transition {
          transition.setAppearance(
            material: values.material, alpha: values.blur, dimAlpha: values.dim)
        } else {
          surface.masked?.setAppearance(
            material: values.material, alpha: values.blur, dimAlpha: values.dim)
        }
      }
      CATransaction.commit()
      Log.info(
        "appearance material=\(values.material.rawValue) blur=\(values.blur) dim=\(values.dim)")
    }
    runner.onTeardown { self.controls?.remove() }
  }

  /// Panels with hidden content must not keep blurring: the WindowServer
  /// applies the radius independently of the panel's drawn content.
  func syncWindowBlur() {
    guard windowBlur else { return }
    for surface in surfaces {
      let visible = surface.panel.contentView?.isHidden == false
      let radius = visible ? Int(blurRadius.rounded()) : 0
      guard radius != surface.appliedRadius else { continue }
      let result = WindowBlur.apply(radius: radius, to: surface.panel)
      if result == 0 {
        surface.appliedRadius = radius
      } else {
        Log.info(
          "window blur failed displayID=\(surface.display.displayID) radius=\(radius) "
            + "error=\(result.map(String.init) ?? "unavailable")")
      }
    }
  }

  /// Main panels plus ramp panels while they are on screen.
  var ownIDs: Set<CGWindowID> {
    Set(
      surfaces.map { CGWindowID($0.panel.windowNumber) }
        + surfaces.compactMap(\.blurRamp).filter { $0.panel.isVisible }.map {
          CGWindowID($0.panel.windowNumber)
        })
  }

  /// One check: snapshot, focus, plan, verify, and repair or update the mask.
  func tick(reason: String) {
    driftChecks += 1
    let all = WindowList.onScreen(includeDesktop: true)
    let foreign = all.filter { $0.pid != getpid() }
    if forcedTarget == nil && (follows || target == nil) {
      let focus = focusTracker.resolve(windows: foreign)
      let resolved = FocusContinuity.target(
        resolved: focus.window, previous: target,
        ownUIIsActive: NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())
      if let window = resolved {
        if window.id != target?.id {
          Log.info(
            "focus: \(window.shortDescription) [\(focus.confidence.rawValue) via \(focus.method)]")
          // Polls often see the new frontmost app before its window is raised
          // and before the activation notification arrives.
          if target != nil { focusChangedAt = DispatchTime.now() }
        }
      }
      target = resolved
    }
    // Unavailable foreign focus removes the effect. Only explicit own-UI
    // interaction may retain a previous target, which must still be on screen.
    guard let current = target, let fresh = foreign.first(where: { $0.id == current.id }) else {
      if target != nil || isEffectVisible { Log.info("focus unknown and target gone: hiding") }
      target = nil
      for surface in surfaces {
        surface.transition?.cancel(reason: "focus-unavailable")
        surface.plan = nil
      }
      setEffectVisible(false)
      return
    }
    target = fresh
    if reason == "initial" {
      for window in foreign where window.layer != 0 {
        Log.observed(
          "surface \(window.shortDescription) bundle=\(window.bundleID ?? "unknown") desktopWidget=\(window.isDesktopWidget)"
        )
      }
    }
    let global = Anchoring.plan(frontToBack: foreign, focused: fresh)
    var deferred = false
    // The display showing the focus changes visibly; handle it before others
    // so their mask rasterization does not delay its reorder.
    let ordered = surfaces.sorted {
      $0.area.intersects(fresh.bounds) && !$1.area.intersects(fresh.bounds)
    }
    for surface in ordered {
      // While the focus display waits for the raised window, the others wait
      // too: their mask work would only delay its next check.
      if deferred { continue }
      var local = surface.failureCache.applying(
        to: DisplayPlacement.plan(global, screen: surface.display.quartzBounds))
      let desired: Placement = local.anchor.map { .below($0.id) } ?? .overlay
      if Self.defersOverlay(
        desired: desired, current: surface.placement,
        since: [pendingActivation?.start, focusChangedAt].compactMap { $0 }.max())
      {
        deferred = true
        continue
      }
      if rampsOutgoingFocus(surface, to: local, windows: foreign) { continue }
      let correct = verify(surface, plan: local, all: all)
      let needsOrder = surface.placement != desired || !correct
      let maskChanged =
        surface.plan.map {
          maskSignature($0, on: surface.area) != maskSignature(local, on: surface.area)
        } ?? true
      if needsOrder || maskChanged {
        if !correct { drifts += 1 }
        surface.raisedSharp =
          needsOrder && maskMode == "full" ? raisedSharpPath(surface, all: all, plan: local) : nil
        apply(surface, plan: local, placement: desired, reason: reason, reorder: needsOrder)
        surface.raisedSharp = nil
        if !verify(surface, plan: local, all: WindowList.onScreen(includeDesktop: true)),
          local.anchor != nil
        {
          surface.failureCache.record(local)
          local = Anchoring.fallback(
            local, reason: "display frame or local order failed verification")
          apply(surface, plan: local, placement: .overlay, reason: reason)
        }
      }
      surface.plan = local
      let verified = verify(surface, plan: local, all: WindowList.onScreen(includeDesktop: true))
      surface.verifiedChecks = verified ? surface.verifiedChecks + 1 : 0
      let visible = verified && (spaceHiddenAt == nil || surface.verifiedChecks >= 2)
      if !verified {
        surface.transition?.cancel(reason: "placement-unavailable")
        surface.plan = nil
      }
      surface.panel.contentView?.isHidden = !visible
    }
    isEffectVisible = surfaces.contains { $0.panel.contentView?.isHidden == false }
    if let hiddenAt = spaceHiddenAt, surfaces.allSatisfy({ $0.verifiedChecks >= 2 }) {
      spaceRecovery.add(Log.elapsedMilliseconds(since: hiddenAt))
      spaceHiddenAt = nil
    }
    // A deferred display has not reached the activated window's order yet;
    // keep the activation pending so the burst keeps checking.
    if isEffectVisible, !deferred, let pending = pendingActivation, target?.pid == pending.pid {
      activationToVerified.add(Log.elapsedMilliseconds(since: pending.start))
      pendingActivation = nil
    }
    // Check at burst rate until the deferred display reaches its anchor.
    if deferred && !settling { burst() }
    settling = deferred
    syncWindowBlur()
    CATransaction.flush()
  }

  /// The newly focused window reaches the front of CGWindowList a few frames
  /// after the frontmost app changes. Falling back to overlay in between reorders twice and
  /// flashes, so an anchored display keeps its verified placement briefly.
  static let activationGrace = 250.0

  static func defersOverlay(desired: Placement, current: Placement, since: DispatchTime?) -> Bool {
    guard desired == .overlay, case .below = current, let since else { return false }
    return Log.elapsedMilliseconds(since: since) < activationGrace
  }

  /// Union of the foreign normal windows above this panel that the
  /// new plan does not protect, in the surface's local coordinates.
  func raisedSharpPath(_ surface: Surface, all: [CGWin], plan: AnchorPlan) -> CGPath? {
    guard surface.panel.contentView?.isHidden == false,
      let index = all.firstIndex(where: { $0.id == CGWindowID(surface.panel.windowNumber) })
    else { return nil }
    var path: CGPath?
    for window in all[..<index]
    where window.pid != getpid() && window.isNormalLevel && window.isMaskEligible
      && !plan.groupIDs.contains(window.id) && window.bounds.intersects(surface.area)
    {
      let shape = MaskPath.roundedRect(
        MaskPath.local(window.bounds, screen: surface.area, flipped: false), cornerRadius)
      path = path?.union(shape) ?? shape
    }
    return path
  }

  func verify(_ surface: Surface, plan: AnchorPlan, all: [CGWin]) -> Bool {
    let number =
      surface.panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
      as? NSNumber
    return DisplayPlacement.verify(
      frontToBack: all, panelID: CGWindowID(surface.panel.windowNumber), ownIDs: ownIDs,
      expected: surface.area, displayID: surface.display.displayID,
      actualDisplayID: number?.uint32Value, plan: plan)
  }

  /// Hide just this display until its frame, screen identity and ordering agree
  /// with the mask. Other displays keep their independently verified effect.
  func apply(
    _ surface: Surface, plan: AnchorPlan, placement desired: Placement, reason: String,
    reorder: Bool = true
  ) {
    let start = DispatchTime.now()
    // In full mode every new focus pixel is punched out BEFORE ordering. A
    // visible, correctly framed panel can move between safe placements without
    // a clear-display frame. Geometry/identity failures still hide for repair.
    let snapshot = WindowList.onScreen(includeDesktop: true)
    let panelInfo = snapshot.first { $0.id == CGWindowID(surface.panel.windowNumber) }
    let framed =
      panelInfo.map {
        $0.isOnScreen && $0.bounds.equalTo(surface.area)
          && (surface.panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value == surface.display.displayID
      } ?? false
    if reorder && (maskMode != "full" || !framed) {
      surface.panel.contentView?.isHidden = true
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if reorder && maskMode == "full" {
      let guarded = FullFocusMask.reorderGuard(
        from: surface.plan, to: plan, exceptions: exceptions(in: plan), screen: surface.area,
        cornerRadius: cornerRadius)
      surface.transition?.guardPlacement(
        surface.raisedSharp.map { guarded.subtracting($0) } ?? guarded)
      Log.info("protection displayID=\(surface.display.displayID) mode=transient-guard")
    } else {
      updateMask(surface: surface, plan: plan)
    }
    CATransaction.commit()
    CATransaction.flush()
    // Ordering applies immediately in the WindowServer, the new mask only
    // after the render server composites it. Without this pause the outgoing
    // focus is briefly covered by the old, filled mask. Both windows stay
    // sharp meanwhile, so the wait is invisible.
    if reorder && maskMode == "full" && surface.panel.contentView?.isHidden == false {
      Thread.sleep(forTimeInterval: guardSettle)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let expected = surface.display.appKitFrame
    if reorder {
      surface.panel.setFrame(expected, display: false)
      switch desired {
      case .below(let anchor):
        surface.panel.level = .normal
        surface.panel.order(.below, relativeTo: Int(anchor))
      case .overlay:
        surface.panel.level = overlayLevel
        surface.panel.orderFrontRegardless()
      case .none:
        surface.panel.orderOut(nil)
      }
      // Relative ordering may change placement. Restore the target frame before
      // checking both AppKit identity and WindowServer bounds, never just z-order.
      surface.panel.setFrame(expected, display: false)
    }
    CATransaction.commit()
    CATransaction.flush()
    if reorder && maskMode == "full"
      && verify(surface, plan: plan, all: WindowList.onScreen(includeDesktop: true))
    {
      updateMask(surface: surface, plan: plan)
      CATransaction.flush()
    }
    if reorder {
      applies.add(Log.elapsedMilliseconds(since: start))
    } else {
      maskUpdates.add(Log.elapsedMilliseconds(since: start))
    }
    if desired == .overlay && surface.placement != .overlay { overlayFallbacks += 1 }
    surface.placement = desired
    if reorder { logPlacement(surface, plan: plan, label: reason) }
  }

  func logPlacement(_ surface: Surface, plan: AnchorPlan, label: String) {
    let all = WindowList.onScreen(includeDesktop: true)
    let actual = all.first { $0.id == CGWindowID(surface.panel.windowNumber) }
    Log.verified(
      "\(label) displayID=\(surface.display.displayID) scale=\(surface.display.scale) "
        + "panel=#\(surface.panel.windowNumber) placement=\(surface.placement) "
        + "expected=\(CGWin.format(surface.area)) actual=\(CGWin.format(actual?.bounds ?? .null)) "
        + "runtimeDisplayID=\(surface.panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "missing") "
        + "contentHidden=\(surface.panel.contentView?.isHidden ?? true) z=\(WindowList.zIndex(of: CGWindowID(surface.panel.windowNumber), in: all) ?? -1) "
        + "anchor=\(plan.anchor?.id ?? 0) group=\(plan.group.map(\.id)) (\(plan.reason))",
      passed: verify(surface, plan: plan, all: all))
  }

  /// Exception windows: listed window ids, or all windows of a listed pid.
  func exceptions(in plan: AnchorPlan) -> Set<CGWindowID> {
    guard !exceptionValues.isEmpty else { return [] }
    return Set(
      plan.normal.filter {
        exceptionValues.contains($0.id) || exceptionValues.contains(UInt32(bitPattern: $0.pid))
      }.map(\.id))
  }

  func maskSignature(_ plan: AnchorPlan, on screen: CGRect) -> String {
    let excluded = exceptions(in: plan)
    let pieces: [MaskPiece]
    switch maskMode {
    case "full":
      pieces = Anchoring.scopeHoles(
        for: plan,
        exceptions: excluded
      )
      .filter { $0.rect.intersects(screen) }
    case "tiles": return Anchoring.maskSignature(for: plan) + "|\(excluded.sorted())"
    default: pieces = Anchoring.pieces(for: plan, exceptions: excluded)
    }
    return
      "focus=\(plan.focused.id)|group=\(plan.groupIDs.sorted())|anchored=\(plan.anchor != nil)|"
      + pieces.map { "\($0.kind)\($0.rect)" }.joined(separator: ";")
  }

  func updateMask(surface: Surface, plan newPlan: AnchorPlan) {
    let excluded = exceptions(in: newPlan)
    switch maskMode {
    case "tiles":
      surface.tiles?.layout(
        quartzRects: Anchoring.effectRects(for: newPlan, exceptions: excluded)
          .map { $0.intersection(surface.display.scopeQuartzBounds) }.filter {
            !$0.isNull && !$0.isEmpty
          })
    case "full":
      guard surface.transition != nil else { return }
      let path = FullFocusMask.path(
        for: newPlan, exceptions: excluded, screen: surface.area, cornerRadius: cornerRadius)
      let focusOutgoing = FullFocusMask.outgoing(
        from: surface.plan, to: newPlan, exceptions: excluded, screen: surface.area,
        cornerRadius: cornerRadius)
      let outgoing =
        [focusOutgoing, surface.raisedSharp].compactMap { $0 }.reduce(nil as CGPath?) {
          $0?.union($1) ?? $1
        }
      if surface.blurRamp != nil {
        updateWindowBlurMask(surface, path: path)
        return
      }
      surface.transition?.retarget(
        path, animate: surface.panel.contentView?.isHidden == false && outgoing != nil,
        outgoing: outgoing,
        retirementClip: FullFocusMask.path(
          for: newPlan, exceptions: excluded, screen: surface.area,
          cornerRadius: cornerRadius, guardPlacement: true))
      Log.info(
        "protection displayID=\(surface.display.displayID) "
          + "mode=\(newPlan.anchor == nil ? "fallback-holes" : "physical-anchor") "
          + "group=\(newPlan.groupIDs.sorted()) exceptions=\(excluded.count)")
    default:
      guard let masked = surface.masked else { return }
      masked.apply(
        path: MaskPath.painter(
          pieces: Anchoring.pieces(for: newPlan, exceptions: excluded)
            + [
              MaskPiece(
                rect: CGRect(
                  x: surface.area.minX, y: surface.area.minY,
                  width: surface.area.width, height: surface.display.menuBarInset), kind: .punch)
            ], screen: surface.area,
          cornerRadius: cornerRadius, flipped: masked.host.isFlipped))
    }
  }

  /// `--blur window`: the WindowServer blur ignores drawn alpha, so masks
  /// only shape the dim; transitions are handled by `rampsOutgoingFocus`.
  func updateWindowBlurMask(_ surface: Surface, path: CGPath) {
    surface.transition?.retarget(path, animate: false)
  }

  /// On a focus switch the main surface stays below the outgoing window while
  /// a ramp panel above it blurs it in; the reorder follows when the ramp
  /// ends. Returns true while this display must not be reordered.
  func rampsOutgoingFocus(_ surface: Surface, to plan: AnchorPlan, windows: [CGWin]) -> Bool {
    guard let ramp = surface.blurRamp else { return false }
    if ramp.isRunning {
      if surface.rampedFocus == plan.focused.id { return true }
      // Another switch during the ramp: finish instantly and reorder now.
      ramp.cancel()
      return false
    }
    guard transitionDuration > 0, surface.panel.contentView?.isHidden == false,
      surface.rampedFocus != plan.focused.id,
      let previous = surface.plan?.focused, previous.id != plan.focused.id,
      case .below(let anchor) = surface.placement, anchor == previous.id,
      let outgoing = windows.first(where: { $0.id == previous.id })
    else { return false }
    let visible = outgoing.bounds.intersection(surface.area)
    guard !visible.isNull, !visible.isEmpty else { return false }
    surface.rampedFocus = plan.focused.id
    ramp.start(
      covering: visible, above: outgoing.id, level: surface.panel.level, radius: blurRadius,
      dimAlpha: currentDim, cornerRadius: cornerRadius, duration: transitionDuration
    ) {
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.tick(reason: "ramp-end") }
      }
    }
    Log.info(
      "window blur ramp displayID=\(surface.display.displayID) over=#\(outgoing.id) "
        + "duration=\(transitionDuration)")
    return true
  }

  func setEffectVisible(_ visible: Bool) {
    guard visible != isEffectVisible else { return }
    isEffectVisible = visible
    for surface in surfaces { surface.panel.contentView?.isHidden = !visible }
    syncWindowBlur()
    CATransaction.flush()
  }

  func report(label: String) {
    for surface in surfaces {
      if let plan = surface.plan { logPlacement(surface, plan: plan, label: label) }
    }
    Log.manual(
      "VERIFIED placement checks geometry/order only; native blur visibility requires visual acceptance"
    )
  }

  func observeActivation() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
      let start = DispatchTime.now()
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        guard let app, app.processIdentifier != getpid() else { return }
        self.pendingActivation = (app.processIdentifier, app.localizedName ?? "?", start)
        self.tick(reason: "activated \(app.localizedName ?? "?")")
        self.burst()
      }
    }
    Log.manual(
      "--follow: click blurred windows of other apps and Cmd-` within one app; watch for sharp flashes"
    )
  }

  /// The activated app's window often reaches the front of CGWindowList only
  /// after the notification: check at ~60 Hz for up to one second.
  func burst() {
    fastTimer?.invalidate()
    let until = Date().addingTimeInterval(1)
    fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard
          Date() < until,
          self.pendingActivation != nil || self.spaceHiddenAt != nil || self.settling
        else {
          if let pending = self.pendingActivation {
            Log.observed("activation of \(pending.name) did not reach a verified order within 1s")
            self.pendingActivation = nil
          }
          self.fastTimer?.invalidate()
          return
        }
        self.tick(reason: "burst")
      }
    }
  }

  func observeSpaces() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        Log.info("active space changed: hiding effect until the order is verified")
        for surface in self.surfaces {
          surface.blurRamp?.cancel()
          surface.transition?.cancel(reason: "space")
          surface.plan = nil
          surface.failureCache.reset()
          surface.verifiedChecks = 0
        }
        self.spaceHiddenAt = DispatchTime.now()
        self.setEffectVisible(false)
        self.burst()
      }
    }
  }
}

let runner = SpikeRunner()
var variant: VariantC?
runner.run(duration: args.double("duration", default: 8)) { runner in
  variant = VariantC(runner: runner)
  variant?.start()
}
