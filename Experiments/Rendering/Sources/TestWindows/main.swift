import AppKit
import SpikeKit

// Controlled target windows for the variants: high-frequency checkerboards
// (blur is obvious), large labels, optional identical titles and a floating
// utility panel. With --script it activates itself, cycles the key window,
// then hands activation back to the previously frontmost app.
//
// Usage: swift run TestWindows [--duration 20] [--count 3] [--same-title]
//   [--panel] [--script] [--step 1]

let args = Args()

final class CheckerView: NSView {
  let label: String

  init(frame: NSRect, label: String) {
    self.label = label
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let cell: CGFloat = 6
    NSColor.white.setFill()
    bounds.fill()
    NSColor.black.setFill()
    for row in 0..<Int(bounds.height / cell) + 1 {
      for column in 0..<Int(bounds.width / cell) + 1 where (row + column) % 2 == 0 {
        NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
      }
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.systemRed,
      .backgroundColor: NSColor.white,
    ]
    label.draw(at: NSPoint(x: 24, y: bounds.height - 80), withAttributes: attributes)
  }
}

@MainActor
final class TestWindows {
  let runner: SpikeRunner
  var windows: [NSWindow] = []
  var keyIndex = 0

  init(runner: SpikeRunner) { self.runner = runner }

  func start() {
    let previous = NSWorkspace.shared.frontmostApplication
    let count = max(1, args.int("count", default: 3))
    let main = Displays.all().first { $0.isMain } ?? Displays.all()[0]
    for index in 0..<count {
      let origin = CGPoint(
        x: main.appKitFrame.minX + 120 + CGFloat(index) * 160,
        y: main.appKitFrame.maxY - 620 - CGFloat(index) * 60)
      let window = NSWindow(
        contentRect: CGRect(origin: origin, size: CGSize(width: 640, height: 420)),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = args.flag("same-title") ? "Sonorus Test" : "Sonorus Test \(index + 1)"
      window.contentView = CheckerView(frame: .zero, label: "TW-\(index + 1)")
      window.isReleasedWhenClosed = false
      window.makeKeyAndOrderFront(nil)
      runner.track(window)
      windows.append(window)
    }
    if args.flag("panel") {
      let panel = NSPanel(
        contentRect: CGRect(
          x: main.appKitFrame.minX + 900, y: main.appKitFrame.maxY - 400, width: 260, height: 200),
        styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
      panel.title = "Sonorus Tool Panel"
      panel.contentView = CheckerView(frame: .zero, label: "P")
      panel.isFloatingPanel = true
      panel.orderFront(nil)
      runner.track(panel)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      for window in self.windows {
        Log.observed(
          "test window #\(window.windowNumber) \"\(window.title)\" frame(quartz)=\(CGWin.format(Coordinates.quartz(fromAppKit: window.frame)))"
        )
      }
    }
    guard args.flag("script") else { return }
    let step = args.double("step", default: 1)
    NSApp.activate()
    Log.info("activated TestWindows; key window #\(windows.last?.windowNumber ?? 0)")
    Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
      MainActor.assumeIsolated {
        self.keyIndex += 1
        if self.keyIndex < self.windows.count {
          let window = self.windows[self.keyIndex - 1]
          window.makeKeyAndOrderFront(nil)
          Log.info("same-app switch: key window now #\(window.windowNumber)")
        } else if self.keyIndex == self.windows.count, let previous {
          let ok = previous.activate()
          Log.info("handed activation back to \(previous.localizedName ?? "?"): \(ok)")
        }
      }
    }
  }
}

let runner = SpikeRunner()
var helper: TestWindows?
runner.run(duration: args.double("duration", default: 20), policy: .regular) { runner in
  helper = TestWindows(runner: runner)
  helper?.start()
}
