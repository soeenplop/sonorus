import AppKit
import ApplicationServices
import SpikeKit

// Focus tracking probe: AXFocusedWindow -> CGWindowList mapping with public
// APIs only, plus timing of the building blocks. Never prompts for a
// permission; without Accessibility it reports the failure and the fallback.
//
// Usage: swift run FocusProbe [--watch 20] [--poll-ms 50] [--titles]

let args = Args()
CGWin.showTitles = args.flag("titles")

@MainActor
final class FocusProbe {
  let runner: SpikeRunner
  var lastFocusID: CGWindowID?
  var observer: AXObserver?
  var observedPID: pid_t = 0
  var activationAt: DispatchTime?
  var switchLatency = Samples()
  var events = 0

  init(runner: SpikeRunner) { self.runner = runner }

  func start(watch: TimeInterval) {
    SpikeEnvironment.report()
    let windows = WindowList.onScreen()
    let result = FocusResolver.resolve(windows: windows)
    report(result, prefix: "initial")
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
      let ax = Samples.measure(50) { _ = FocusResolver.focusedAXWindow(pid: pid) }
      Log.observed("AXFocusedWindow + attributes cost: \(ax.summary)")
      if FocusResolver.isAccessibilityTrusted { listAXWindows(pid: pid, cgWindows: windows) }
    }
    let list = Samples.measure(50) { _ = WindowList.onScreen() }
    Log.observed("CGWindowList snapshot cost: \(list.summary)")
    let full = Samples.measure(50) { _ = FocusResolver.resolve(windows: WindowList.onScreen()) }
    Log.observed("full resolve (snapshot + AX + matching) cost: \(full.summary)")
    if !FocusResolver.isAccessibilityTrusted {
      Log.observed(
        "AX not trusted: AXFocusedWindow fails (kAXErrorAPIDisabled = -25211); only the "
          + "frontmost-app heuristic is available, confidence capped at 'uncertain'")
      Log.manual(
        "grant Accessibility to the launching terminal app, rerun with --watch 30 and switch "
          + "windows via click, Cmd-Tab and Cmd-` (same app)")
    }
    guard watch > 0 else { runner.finish(code: 0) }
    lastFocusID = result.window?.id
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        self.activationAt = .now()
        Log.info("NSWorkspace didActivateApplication: \(app?.localizedName ?? "?")")
        self.attachAXObserver()
        self.poll(source: "activation")
      }
    }
    attachAXObserver()
    let interval = args.double("poll-ms", default: 50) / 1000
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { self.poll(source: "poll") }
    }
    runner.onTeardown {
      Log.observed("activation -> new focused CG window resolved: \(self.switchLatency.summary)")
      Log.observed("AX notifications received: \(self.events)")
    }
    Log.manual("watching for \(watch)s: switch focus between windows now")
  }

  func poll(source: String) {
    let result = FocusResolver.resolve(windows: WindowList.onScreen())
    guard result.window?.id != lastFocusID else { return }
    lastFocusID = result.window?.id
    if let activationAt {
      switchLatency.add(Log.elapsedMilliseconds(since: activationAt))
      self.activationAt = nil
    }
    report(result, prefix: "focus changed (\(source))")
  }

  func report(_ result: FocusResult, prefix: String) {
    let window = result.window?.shortDescription ?? "none"
    var ax = ""
    if let info = result.axWindow {
      let title = info.title.map { CGWin.showTitles ? $0 : "<\($0.count) chars>" } ?? "nil"
      ax =
        " ax{role=\(info.role ?? "?") subrole=\(info.subrole ?? "?") title=\(title) "
        + "frame=\(info.frame.map(CGWin.format) ?? "nil") minimized=\(info.isMinimized.map(String.init) ?? "?") "
        + "fullScreen=\(info.isFullScreen.map(String.init) ?? "?")}"
    }
    Log.observed(
      "\(prefix): \(result.confidence.rawValue) via \(result.method) candidates=\(result.candidates) "
        + "[\(result.detail)] -> \(window)\(ax)")
  }

  /// Lists every AX window of the app and how many CG windows share its frame;
  /// >1 means the frame match alone is ambiguous (tabs, stacked windows).
  func listAXWindows(pid: pid_t, cgWindows: [CGWin]) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let axWindows = value as? [AXUIElement]
    else { return }
    let sameApp = cgWindows.filter { $0.pid == pid && $0.isNormalLevel }
    for element in axWindows {
      let info = FocusResolver.info(for: element, pid: pid)
      let matches = info.frame.map { frame in
        sameApp.filter {
          abs($0.bounds.minX - frame.minX) <= 2 && abs($0.bounds.minY - frame.minY) <= 2
            && abs($0.bounds.width - frame.width) <= 2 && abs($0.bounds.height - frame.height) <= 2
        }.count
      }
      Log.observed(
        "AX window subrole=\(info.subrole ?? "?") frame=\(info.frame.map(CGWin.format) ?? "nil") "
          + "-> \(matches ?? 0) CG frame matches")
    }
  }

  func attachAXObserver() {
    guard FocusResolver.isAccessibilityTrusted,
      let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != observedPID
    else { return }
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, notification, refcon in
      guard let refcon else { return }
      let probe = Unmanaged<FocusProbe>.fromOpaque(refcon).takeUnretainedValue()
      let name = notification as String
      MainActor.assumeIsolated {
        probe.events += 1
        Log.info("AX notification \(name)")
        probe.poll(source: name)
      }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    let app = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [
      kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
      kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
      kAXUIElementDestroyedNotification,
    ] {
      let error = AXObserverAddNotification(created, app, name as CFString, refcon)
      if error != .success { Log.info("AXObserverAddNotification \(name) -> \(error.rawValue)") }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    observer = created
    observedPID = pid
    Log.info("AX observer attached to pid \(pid)")
  }
}

let runner = SpikeRunner()
var probe: FocusProbe?
let watch = args.double("watch", default: 0)
runner.run(duration: max(watch, 1) + 2) { runner in
  probe = FocusProbe(runner: runner)
  probe?.start(watch: watch)
}
