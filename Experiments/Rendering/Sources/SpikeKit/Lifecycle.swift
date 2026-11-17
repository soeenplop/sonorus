import AppKit

/// Runs a spike as an accessory app (no Dock icon, never activated) and
/// guarantees that overlays disappear: on timeout, on SIGINT/SIGTERM/SIGHUP,
/// and via a hard watchdog that kills the process if the main thread hangs.
/// Overlay windows belong to this process, so process exit always removes them.
@MainActor
public final class SpikeRunner {
  public private(set) var windows: [NSWindow] = []
  private var teardownHandlers: [@MainActor () -> Void] = []
  private var signalSources: [DispatchSourceSignal] = []
  private var watchdog: DispatchSourceTimer?
  private var finished = false
  private var activationObserver: NSObjectProtocol?
  public private(set) var frontBefore: NSRunningApplication?
  public private(set) var activationCount = 0
  /// Disable with `--keep-activation` to observe the raw activation behaviour.
  public var returnFocus = !CommandLine.arguments.contains("--keep-activation")

  public init() {}

  public func track(_ window: NSWindow) { windows.append(window) }

  public func onTeardown(_ handler: @escaping @MainActor () -> Void) {
    teardownHandlers.append(handler)
  }

  /// Starts the AppKit run loop; `setup` runs once the app has launched.
  public func run(
    duration: TimeInterval, policy: NSApplication.ActivationPolicy = .accessory,
    setup: @escaping @MainActor (SpikeRunner) -> Void
  ) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(policy)
    if policy != .accessory { returnFocus = false }
    installSignalHandlers()
    installWatchdog(after: duration + 10)
    Log.info("pid \(getpid()); auto-exit after \(duration)s; Ctrl-C exits early")
    let frontBefore = NSWorkspace.shared.frontmostApplication
    self.frontBefore = frontBefore
    // Observed on macOS 27: an unbundled process launched by the frontmost app
    // (e.g. a terminal) inherits its activation when it shows the first window,
    // even as .accessory with a non-activating panel. Record it and hand focus
    // back so the spike measures the user's real target, not itself.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        self.activationCount += 1
        Log.observed(
          "spike app became active (#\(self.activationCount)); previous frontmost: "
            + "\(frontBefore?.localizedName ?? "nil")")
        if self.returnFocus, let frontBefore, frontBefore.processIdentifier != getpid() {
          let returned = frontBefore.activate()
          Log.info("handed activation back to \(frontBefore.localizedName ?? "?"): \(returned)")
        }
      }
    }
    DispatchQueue.main.async {
      setup(self)
      Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
        MainActor.assumeIsolated { self.finish(code: 0) }
      }
      Timer.scheduledTimer(withTimeInterval: min(1, duration / 2), repeats: false) { _ in
        MainActor.assumeIsolated {
          guard policy == .accessory else { return }
          let frontNow = NSWorkspace.shared.frontmostApplication
          Log.verified(
            "frontmost app unchanged after showing overlays (\(frontNow?.localizedName ?? "nil"))",
            passed: frontNow?.processIdentifier == frontBefore?.processIdentifier)
          Log.verified("spike app is not active (NSApp.isActive=false)", passed: !app.isActive)
        }
      }
    }
    app.run()
    exit(0)
  }

  public func finish(code: Int32) -> Never {
    guard !finished else { exit(code) }
    finished = true
    for handler in teardownHandlers { handler() }
    for window in windows {
      window.orderOut(nil)
      window.close()
    }
    let count = windows.count
    windows.removeAll()
    // Let the window server process the order-out (and close animations of
    // titled windows) before checking; give up after one second.
    var leftovers = WindowList.onScreen().filter { $0.pid == getpid() }
    let deadline = Date().addingTimeInterval(1)
    while !leftovers.isEmpty && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      leftovers = WindowList.onScreen().filter { $0.pid == getpid() }
    }
    Log.verified(
      "cleanup removed \(count) own windows; own on-screen windows left: \(leftovers.count)",
      passed: leftovers.isEmpty)
    exit(code)
  }

  private func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          Log.info("signal \(sig) received, cleaning up")
          self?.finish(code: 130)
        }
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func installWatchdog(after seconds: TimeInterval) {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler {
      print("watchdog: main thread did not finish in time, hard exit")
      _exit(3)
    }
    timer.resume()
    watchdog = timer
  }
}
