import AppKit
import SpikeKit

// Variant A: one click-through NSVisualEffectView panel per display above all
// normal windows; a mask image limits the material to the visible parts of
// inactive windows. The focused window and exceptions are punched out.
//
// Usage: swift run VariantA [--duration 8] [--material hudWindow] [--alpha 1]
//   [--dim 0.3] [--layers 1] [--corner-radius 16] [--level 1] [--fade 180]
//   [--follow] [--sweep] [--step 2] [--full] [--no-click-through]
//   [--except 123,456] [--titles]

let args = Args()
CGWin.showTitles = args.flag("titles")

@MainActor
final class VariantA {
  @MainActor final class Surface {
    let display: DisplayInfo
    let panels: [OverlayPanel]
    let effects: [NSVisualEffectView]
    let dim: DimView
    let tiles: TileSurface

    init(
      display: DisplayInfo, panels: [OverlayPanel], effects: [NSVisualEffectView], dim: DimView,
      tiles: TileSurface
    ) {
      self.display = display
      self.panels = panels
      self.effects = effects
      self.dim = dim
      self.tiles = tiles
    }

    var allEffects: [NSVisualEffectView] { effects + tiles.effects }
  }

  let runner: SpikeRunner
  let materialName = args.string("material", default: "hudWindow")
  let effectAlpha = CGFloat(args.double("alpha", default: 1))
  let dimAlpha = CGFloat(args.double("dim", default: 0.3))
  let layers = max(1, args.int("layers", default: 1))
  let cornerRadius = CGFloat(args.double("corner-radius", default: 16))
  let level = NSWindow.Level(
    rawValue: args.int("level", default: NSWindow.Level.normal.rawValue + 1))
  let fullScreen = args.flag("full")
  /// `image`: one full-screen effect view + painter's-algorithm mask image
  /// (rounded corners). `tiles`: one effect view per exact visible rectangle,
  /// no mask image (square corners, much cheaper updates).
  let maskMode = args.string("mask", default: "image")
  let clickThrough = !args.flag("no-click-through")
  let exceptions = Set(args.list("except").compactMap(UInt32.init))
  var surfaces: [Surface] = []
  var lastSignature = ""
  var updates = Samples()
  var activationLatency = Samples()
  var observers: [NSObjectProtocol] = []
  var sweepTimer: Timer?
  let focusTracker = FocusTracker()
  var sweepIndex = 0
  var pendingActivation: (pid: pid_t, start: DispatchTime)?

  init(runner: SpikeRunner) { self.runner = runner }

  func start() {
    SpikeEnvironment.report()
    guard let material = Materials.named(materialName) else {
      Log.info("unknown material \(materialName); options: \(Materials.all.map(\.0))")
      runner.finish(code: 64)
    }
    Log.info(
      "material=\(materialName) alpha=\(effectAlpha) dim=\(dimAlpha) layers=\(layers) "
        + "level=\(level.rawValue) cornerRadius=\(cornerRadius) clickThrough=\(clickThrough) "
        + "full=\(fullScreen) mask=\(maskMode)")
    for display in Displays.all() {
      var panels: [OverlayPanel] = []
      var effects: [NSVisualEffectView] = []
      for _ in 0..<layers {
        let panel = OverlayPanel(
          appKitFrame: display.appKitFrame, level: level, clickThrough: clickThrough)
        let root = FlippedView(frame: CGRect(origin: .zero, size: display.appKitFrame.size))
        let effect = EffectFactory.effectView(material: material, alpha: effectAlpha)
        effect.frame = root.bounds
        effect.isHidden = maskMode == "tiles" && !fullScreen
        root.addSubview(effect)
        panel.contentView = root
        panels.append(panel)
        effects.append(effect)
        runner.track(panel)
      }
      let dim = DimView(frame: panels[0].contentView!.bounds)
      dim.autoresizingMask = [.width, .height]
      dim.dimAlpha = dimAlpha
      panels.last!.contentView!.addSubview(dim)
      let tiles = TileSurface(
        display: display, root: panels[0].contentView!, material: material, alpha: effectAlpha,
        dimAlpha: dimAlpha)
      surfaces.append(
        Surface(display: display, panels: panels, effects: effects, dim: dim, tiles: tiles))
    }
    update(reason: "initial")
    let fade = args.double("fade", default: 180) / 1000
    for surface in surfaces {
      for panel in surface.panels {
        panel.alphaValue = fade > 0 ? 0 : 1
        panel.orderFrontRegardless()
      }
    }
    if fade > 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = fade
        for panel in surfaces.flatMap(\.panels) { panel.animator().alphaValue = 1 }
      }
    }
    Timer.scheduledTimer(withTimeInterval: max(0.3, fade + 0.15), repeats: false) { _ in
      MainActor.assumeIsolated { self.selfTest() }
    }
    if args.flag("follow") { follow() }
    if args.flag("sweep") { sweep(step: args.double("step", default: 2)) }
    runner.onTeardown {
      for observer in self.observers {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      }
      Log.observed("mask update cost (snapshot+mask build+commit): \(self.updates.summary)")
      if !self.activationLatency.values.isEmpty {
        Log.observed("activation notification -> mask committed: \(self.activationLatency.summary)")
      }
    }
  }

  func snapshot() -> (windows: [CGWin], focus: FocusResult) {
    let windows = WindowList.onScreen().filter { $0.pid != getpid() && $0.isMaskEligible }
    return (windows, focusTracker.resolve(windows: windows))
  }

  @discardableResult
  func update(reason: String, force: Bool = false) -> Bool {
    let start = DispatchTime.now()
    let (windows, focus) = snapshot()
    if !fullScreen && focus.window == nil {
      for surface in surfaces { for panel in surface.panels { panel.contentView?.isHidden = true } }
      lastSignature = ""
      return false
    }
    let signature =
      windows.filter(\.isNormalLevel).map { "\($0.id)@\($0.bounds)" }.joined(separator: ";")
      + "|focus=\(focus.window?.id ?? 0)"
    guard force || signature != lastSignature else { return false }
    lastSignature = signature
    let pieces = MaskBuilder.pieces(
      frontToBack: windows, focused: focus.window?.id, exceptions: exceptions)
    let snapshotMs = Log.elapsedMilliseconds(since: start)
    var effectMs = 0.0
    var dimMs = 0.0
    var tileCount = 0
    if maskMode == "tiles" && !fullScreen {
      let step = DispatchTime.now()
      let effectIDs = Set(
        windows.filter {
          $0.isNormalLevel && $0.id != focus.window?.id && !exceptions.contains($0.id)
        }.map(\.id))
      let rects = MaskBuilder.visibleEffectRects(frontToBack: windows, effectIDs: effectIDs)
        .flatMap(\.1)
      tileCount = rects.count
      for surface in surfaces {
        surface.tiles.layout(quartzRects: rects)
        surface.dim.isHidden = true
      }
      effectMs += Log.elapsedMilliseconds(since: step)
    } else {
      for surface in surfaces {
        var step = DispatchTime.now()
        let mask: NSImage? =
          fullScreen
          ? nil
          : MaskBuilder.image(
            for: pieces, screenQuartzBounds: surface.display.quartzBounds,
            cornerRadius: cornerRadius)
        for effect in surface.effects {
          effect.maskImage = mask
          effect.displayIfNeeded()
        }
        effectMs += Log.elapsedMilliseconds(since: step)
        step = DispatchTime.now()
        surface.dim.mask =
          mask
          ?? NSImage(size: surface.display.appKitFrame.size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
          }
        surface.dim.displayIfNeeded()
        dimMs += Log.elapsedMilliseconds(since: step)
      }
    }
    let flushStart = DispatchTime.now()
    CATransaction.flush()
    let flushMs = Log.elapsedMilliseconds(since: flushStart)
    let cost = Log.elapsedMilliseconds(since: start)
    for surface in surfaces { for panel in surface.panels { panel.contentView?.isHidden = false } }
    if let pending = pendingActivation, focus.window?.pid == pending.pid {
      activationLatency.add(Log.elapsedMilliseconds(since: pending.start))
      pendingActivation = nil
    }
    updates.add(cost)
    Log.info(
      String(
        format:
          "update (%@): focus=%@ [%@, %@] pieces=%d tiles=%d cost=%.2fms "
          + "(snapshot %.2f, effect %.2f, dim %.2f, flush %.2f)", reason,
        focus.window.map { "#\($0.id) \($0.owner)" } ?? "none", focus.confidence.rawValue,
        focus.method, pieces.count, tileCount, cost, snapshotMs, effectMs, dimMs, flushMs))
    return true
  }

  func selfTest() {
    let all = WindowList.onScreen()
    let own = all.filter { $0.pid == getpid() }
    Log.verified(
      "\(own.count) own overlay windows on screen (expected \(surfaces.count * layers))",
      passed: own.count == surfaces.count * layers)
    for window in own {
      let matchesDisplay = surfaces.contains { $0.display.quartzBounds == window.bounds }
      Log.verified(
        "overlay #\(window.id) layer=\(window.layer) bounds=\(CGWin.format(window.bounds)) covers one full display",
        passed: matchesDisplay && window.layer == level.rawValue)
    }
    if let topOwn = own.first, let index = WindowList.zIndex(of: topOwn.id, in: all) {
      let normalAbove = all[..<index].filter { $0.isNormalLevel && $0.pid != getpid() }
      Log.verified(
        "no normal-level foreign window is above the overlay (found \(normalAbove.count))",
        passed: normalAbove.isEmpty)
    }

    let (windows, focus) = snapshot()
    let effectIDs = Set(
      windows.filter {
        $0.isNormalLevel && $0.id != focus.window?.id && !exceptions.contains($0.id)
      }
      .map(\.id))
    let visible = MaskBuilder.visibleEffectRects(frontToBack: windows, effectIDs: effectIDs)
    let area = visible.flatMap(\.1).reduce(0) { $0 + $1.width * $1.height }
    Log.observed(
      "effect covers \(visible.filter { !$0.1.isEmpty }.count) inactive windows, "
        + String(format: "%.0f pt² visible (exact rects, before rounding corners)", area))
    let ownIDs = Set(own.map { Int($0.id) })
    // Pick a large visible piece of an inactive window, away from rounded corners.
    let minSide = 4 * cornerRadius
    let pieces: [(CGWin, CGRect)] = visible.flatMap { pair in pair.1.map { (pair.0, $0) } }
    let candidate = pieces.filter { $0.1.width > minSide && $0.1.height > minSide }
      .max { (a: (CGWin, CGRect), b: (CGWin, CGRect)) -> Bool in
        a.1.width * a.1.height < b.1.width * b.1.height
      }
    if let (target, rect) = candidate {
      let point = CGPoint(x: rect.midX, y: rect.midY)
      let hit = HitTest.windowNumber(atQuartz: point)
      Log.verified(
        "hit-test at blurred point (\(Int(point.x)),\(Int(point.y))) of #\(target.id) \(target.owner) "
          + "returns \(hit) (own overlay ids \(ownIDs.sorted()))",
        passed: clickThrough ? hit == Int(target.id) : ownIDs.contains(hit))
    } else {
      Log.info("no visible inactive window piece large enough for a hit test")
    }
    if let focused = focus.window {
      let point = CGPoint(x: focused.bounds.midX, y: focused.bounds.midY)
      let hit = HitTest.windowNumber(atQuartz: point)
      Log.verified(
        "hit-test at focused window centre returns \(hit) (focused #\(focused.id))",
        passed: clickThrough ? hit == Int(focused.id) : true)
    }
    for surface in surfaces {
      let image = MaskBuilder.image(
        for: MaskBuilder.pieces(
          frontToBack: windows, focused: focus.window?.id, exceptions: exceptions),
        screenQuartzBounds: surface.display.quartzBounds, cornerRadius: cornerRadius)
      let raster = Samples.measure(5) {
        var rect = CGRect(origin: .zero, size: image.size)
        let context = NSGraphicsContext(
          bitmapImageRep: NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(surface.display.pixelSize.width),
            pixelsHigh: Int(surface.display.pixelSize.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!)
        _ = image.cgImage(forProposedRect: &rect, context: context, hints: nil)
      }
      Log.observed(
        "mask rasterisation at native pixels \(surface.display.pixelSize) on \(surface.display.name): \(raster.summary)"
      )
    }
    Log.manual(
      "is the material over inactive windows perceived as blur (not just tint)? material=\(materialName) alpha=\(effectAlpha)"
    )
    Log.manual("does the focused window stay sharp incl. its rounded corners and shadow edge?")
  }

  func follow() {
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated { _ = self.update(reason: "poll") }
    }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { note in
        let start = DispatchTime.now()
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        MainActor.assumeIsolated {
          // The new app's window may not be frontmost in CGWindowList yet; force a rebuild.
          if let app { self.pendingActivation = (app.processIdentifier, start) }
          self.update(reason: "activated \(app?.localizedName ?? "?")", force: true)
        }
      })
    Log.manual(
      "--follow: click inactive windows, move/resize them; watch for lag, seams, wrong sharp areas")
  }

  func sweep(step: TimeInterval) {
    let alphas: [CGFloat] = [1, 0.75, 0.5, 0.25]
    var combos: [(String, NSVisualEffectView.Material, CGFloat)] = []
    for (name, material) in Materials.all { combos.append((name, material, 1)) }
    for alpha in alphas.dropFirst() {
      combos.append((materialName, Materials.named(materialName)!, alpha))
    }
    sweepTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard self.sweepIndex < combos.count else {
          self.sweepTimer?.invalidate()
          return
        }
        let (name, material, alpha) = combos[self.sweepIndex]
        for effect in self.surfaces.flatMap(\.allEffects) {
          effect.material = material
          effect.alphaValue = alpha
        }
        Log.manual(
          "sweep \(self.sweepIndex + 1)/\(combos.count): material=\(name) alpha=\(alpha) — note perceived blur"
        )
        self.sweepIndex += 1
      }
    }
  }
}

let runner = SpikeRunner()
var variant: VariantA?
runner.run(duration: args.double("duration", default: 8)) { runner in
  variant = VariantA(runner: runner)
  variant?.start()
}
