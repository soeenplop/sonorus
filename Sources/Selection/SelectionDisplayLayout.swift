import Contracts

/// Decides whether a screen-parameter notification really changed the geometry
/// the selection was built on. Anything else (color profile, refresh rate, …)
/// must not tear down the pass.
enum SelectionDisplayLayout {
  struct Entry: Equatable, Hashable, Sendable {
    let runtimeID: UInt32
    let frame: ScreenRect
  }

  static func entries(of displays: [DisplaySnapshot]) -> Set<Entry> {
    Set(displays.map { Entry(runtimeID: $0.runtimeID, frame: $0.frame) })
  }

  static func hasChanged(from initial: [DisplaySnapshot], to current: Set<Entry>) -> Bool {
    entries(of: initial) != current
  }
}
