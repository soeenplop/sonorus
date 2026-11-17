import SwiftUI

@main
struct SonorusApp: App {
  var body: some Scene {
    MenuBarExtra("Sonorus", systemImage: "circle.dashed") {
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
  }
}
