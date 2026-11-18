import MenuBar
import SwiftUI

@main
struct SonorusApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(model: model.menu)
    } label: {
      MenuBarLabel(model: model.menu)
    }
    .menuBarExtraStyle(.window)
  }
}
