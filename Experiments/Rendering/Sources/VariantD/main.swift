import AppKit
import SpikeKit

// Variant D: per display a full-screen CABackdropLayer panel ordered directly below the
// focused window, no masks. A focus switch orders a second panel below the
// new focus and cross-animates both radii (see `CrossBlur`), so the old focus
// and windows raised by ⌘Tab blur in gradually while the background stays
// constant. Blur and dim are undocumented-API based (user decision).
//
// Usage: swift run VariantD [--duration 90] [--radius 24] [--dim 0.3]
//   [--transition 0.75] [--poll 0.1] [--disables-occluded] [--no-controls]

let args = Args()

@MainActor
final class VariantD {
  /// Two panels per display; `active` is below the current focus.
  final class Pair {
    let display: DisplayInfo
    var active: BackdropPanel
    var spare: BackdropPanel
    var anchor: CGWindowID?
    var finishing: DispatchWorkItem?

    init(display: DisplayInfo, active: BackdropPanel, spare: BackdropPanel) {
      self.display = display
      self.active = active
      self.spare = spare
    }
  }

  let runner: SpikeRunner
  var radius = CGFloat(min(64, max(0, args.double("radius", default: 24))))
  var dim = CGFloat(min(1, max(0, args.double("dim", default: 0.3))))
  let transition = FocusTransition.duration(args.double("transition", default: 0.75))
  let focusTracker = FocusTracker()
  var pairs: [Pair] = []
  var target: CGWin?
  var focusChangedAt: DispatchTime?
  var fastTimer: Timer?
  var controls: EffectControls?
  var switches = Samples()

  init(runner: SpikeRunner) { self.runner = runner }

  func start() {
    SpikeEnvironment.report()
    guard BackdropBlur.isAvailable else {
      Log.info("CABackdropLayer/CAFilter missing on this macOS")
      runner.finish(code: 69)
    }
    let disables = args.flag("disables-occluded")
    for display in Displays.all() {
      guard let first = BackdropPanel(display: display, disablesOccludedBlurs: disables),
        let second = BackdropPanel(display: display, disablesOccludedBlurs: disables)
      else { runner.finish(code: 69) }
      for panel in [first, second] { runner.track(panel.panel) }
      pairs.append(Pair(display: display, active: first, spare: second))
    }
    Log.info(
      "variant D: radius=\(radius) dim=\(dim) transition=\(transition) "
        + "disablesOccludedBackdropBlurs=\(disables)")
    tick(reason: "initial")
    Timer.scheduledTimer(withTimeInterval: args.double("poll", default: 0.1), repeats: true) {
      _ in MainActor.assumeIsolated { self.tick(reason: "poll") }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        self.tick(reason: "activated")
        self.burst()
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        Log.info("active space changed: reordering without transition")
        for pair in self.pairs { pair.anchor = nil }
        self.tick(reason: "space")
        self.burst()
      }
    }
    if !args.flag("no-controls") { installControls() }
    runner.onTeardown {
      self.fastTimer?.invalidate()
      Log.observed("focus switch -> both panels ordered: \(self.switches.summary)")
    }
  }

  func installControls() {
    let initial = EffectControls.Values(material: .hudWindow, blur: radius / 64, dim: dim)
    let title: (CGFloat) -> String = { "Blur-Radius: \(Int(($0 * 64).rounded())) pt" }
    controls = EffectControls(values: initial, blurTitle: title) { values in
      self.radius = values.blur * 64
      self.dim = values.dim
      for pair in self.pairs where pair.finishing == nil && pair.anchor != nil {
        pair.active.set(radius: self.radius, dim: self.dim)
      }
      Log.info("appearance radius=\(Int(self.radius.rounded())) dim=\(self.dim)")
    }
    runner.onTeardown { self.controls?.remove() }
  }

  func tick(reason: String) {
    let all = WindowList.onScreen(includeDesktop: true)
    let foreign = all.filter { $0.pid != getpid() }
    let focus = focusTracker.resolve(windows: foreign)
    let resolved = FocusContinuity.target(
      resolved: focus.window, previous: target,
      ownUIIsActive: NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())
    if let resolved, resolved.id != target?.id {
      Log.info(
        "focus: \(resolved.shortDescription) [\(focus.confidence.rawValue) via \(focus.method)]")
      if target != nil { focusChangedAt = DispatchTime.now() }
    }
    target = resolved
    guard let fresh = resolved.flatMap({ t in foreign.first { $0.id == t.id } }) else {
      for pair in pairs { hide(pair) }
      return
    }
    let global = Anchoring.plan(frontToBack: foreign, focused: fresh)
    for pair in pairs {
      let local = DisplayPlacement.plan(global, screen: pair.display.quartzBounds)
      // Right after a switch the raised window may not be at the front of the
      // window list yet; wait briefly instead of covering it.
      if global.anchor == nil, let changed = focusChangedAt,
        Log.elapsedMilliseconds(since: changed) < 250
      {
        continue
      }
      place(pair, anchor: local.anchor?.id, all: all)
    }
  }

  /// nil anchor: no focus on this display, the panel covers all its windows.
  func place(_ pair: Pair, anchor: CGWindowID?, all: [CGWin]) {
    let wasShown = pair.active.panel.isVisible
    if anchor == pair.anchor, wasShown, isOrdered(pair.active, below: anchor, in: all) { return }
    let isSwitch = wasShown && anchor != pair.anchor && pair.anchor != nil && transition > 0
    if isSwitch {
      crossTo(anchor, pair: pair)
    } else {
      order(pair.active, below: anchor)
      pair.active.set(radius: radius, dim: dim)
    }
    pair.anchor = anchor
  }

  func crossTo(_ anchor: CGWindowID?, pair: Pair) {
    let start = DispatchTime.now()
    finish(pair)
    let incoming = pair.spare
    let outgoing = pair.active
    incoming.set(radius: 0, dim: 0)
    order(incoming, below: anchor)
    let samples = CrossBlur.samples(24)
    let (radius, dim) = (self.radius, self.dim)
    incoming.animate(duration: transition, samples: samples) {
      (CrossBlur.incomingRadius(radius, progress: $0), CrossBlur.incomingDim(dim, progress: $0))
    }
    outgoing.animate(duration: transition, samples: samples) {
      (CrossBlur.outgoingRadius(radius, progress: $0), CrossBlur.outgoingDim(dim, progress: $0))
    }
    pair.active = incoming
    pair.spare = outgoing
    let work = DispatchWorkItem { [weak pair] in
      MainActor.assumeIsolated {
        guard let pair else { return }
        self.finish(pair)
      }
    }
    pair.finishing = work
    DispatchQueue.main.asyncAfter(deadline: .now() + transition, execute: work)
    switches.add(Log.elapsedMilliseconds(since: start))
    Log.info(
      "cross displayID=\(pair.display.displayID) below=#\(anchor.map(String.init) ?? "top") "
        + "duration=\(transition)")
  }

  /// Ends a running cross-fade: the outgoing panel leaves, the incoming one
  /// keeps its final values.
  func finish(_ pair: Pair) {
    guard let work = pair.finishing else { return }
    work.cancel()
    pair.finishing = nil
    pair.active.set(radius: radius, dim: dim)
    pair.spare.set(radius: 0, dim: 0)
    pair.spare.panel.orderOut(nil)
  }

  func hide(_ pair: Pair) {
    finish(pair)
    pair.active.panel.orderOut(nil)
    pair.anchor = nil
  }

  func order(_ panel: BackdropPanel, below anchor: CGWindowID?) {
    if let anchor {
      panel.panel.order(.below, relativeTo: Int(anchor))
    } else {
      panel.panel.orderFrontRegardless()
    }
  }

  /// The panel sits directly below the anchor (only own panels in between),
  /// or, without an anchor, above every normal window on its display.
  func isOrdered(_ panel: BackdropPanel, below anchor: CGWindowID?, in all: [CGWin]) -> Bool {
    let own = CGWindowID(panel.panel.windowNumber)
    guard let index = all.firstIndex(where: { $0.id == own }) else { return false }
    let screen = panel.display.quartzBounds
    let above = all[..<index].filter {
      $0.pid != getpid() && $0.isNormalLevel && $0.isMaskEligible && $0.bounds.intersects(screen)
    }
    guard let anchor else { return above.isEmpty }
    return above.last?.id == anchor
  }

  func burst() {
    fastTimer?.invalidate()
    let until = Date().addingTimeInterval(0.5)
    fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard Date() < until else {
          self.fastTimer?.invalidate()
          return
        }
        self.tick(reason: "burst")
      }
    }
  }
}

let runner = SpikeRunner()
var variant: VariantD?
runner.run(duration: args.double("duration", default: 90)) { runner in
  variant = VariantD(runner: runner)
  variant?.start()
}
