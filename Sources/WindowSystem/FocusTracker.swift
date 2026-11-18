import Contracts

struct FocusState: Equatable {
  var window: WindowReference?
  var confidence: FocusConfidence
  var associated: Set<WindowReference> = []

  static let unavailable = FocusState(window: nil, confidence: .unavailable)
}

/// Resolves the work window from the frontmost application and the current
/// windows, without Accessibility:
///
/// - The frontmost normal window of the frontmost app is the target. It is a
///   guess from the window order, so it is always `.uncertain`.
/// - Popups, suggestion lists and sheets are often normal windows of the same
///   app in front of the real one. A window in front that is less than half
///   the size of a later window of the app and lies mostly on it is treated as
///   associated: it stays sharp, and the larger window remains the target.
/// - Sonorus never becomes the target: while it is frontmost, or while a
///   freeze is active, the previous target is kept as long as it exists.
struct FocusTracker {
  let ownPID: Int32
  private(set) var isFrozen = false
  private(set) var state = FocusState.unavailable

  init(ownPID: Int32) {
    self.ownPID = ownPID
  }

  mutating func freeze() { isFrozen = true }
  mutating func unfreeze() { isFrozen = false }

  mutating func resolve(frontmostPID pid: Int32?, windows: [CatalogWindow]) -> FocusState {
    state = isFrozen || pid == ownPID ? kept(in: windows) : Self.front(of: pid, in: windows)
    return state
  }

  private static func front(of pid: Int32?, in windows: [CatalogWindow]) -> FocusState {
    let own = windows.filter { $0.isNormal && $0.reference.ownerPID == pid }
    var associated: Set<WindowReference> = []
    for (index, window) in own.enumerated() {
      if own[(index + 1)...].contains(where: { isAuxiliary(window, of: $0) }) {
        associated.insert(window.reference)
      } else {
        return FocusState(window: window.reference, confidence: .uncertain, associated: associated)
      }
    }
    return .unavailable
  }

  static func isAuxiliary(_ window: CatalogWindow, of main: CatalogWindow) -> Bool {
    let frame = window.snapshot.frame
    let mainFrame = main.snapshot.frame
    guard frame.area < mainFrame.area / 2, let overlap = frame.intersection(mainFrame) else {
      return false
    }
    return overlap.area >= frame.area / 2
  }

  private func kept(in windows: [CatalogWindow]) -> FocusState {
    let present = Set(windows.map(\.reference))
    guard let current = state.window, present.contains(current) else { return .unavailable }
    return FocusState(
      window: current, confidence: state.confidence,
      associated: state.associated.intersection(present))
  }
}
