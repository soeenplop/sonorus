import Contracts

struct FocusState: Equatable {
  var window: WindowReference?
  var confidence: FocusConfidence

  static let unavailable = FocusState(window: nil, confidence: .unavailable)
}

/// Resolves the work window from the frontmost application and the current
/// windows, without Accessibility:
///
/// - The frontmost normal window of the frontmost app is the target. It is a
///   guess from the window order, so it is always `.uncertain`.
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
    let target: (WindowReference?, FocusConfidence)
    if isFrozen || pid == ownPID {
      target = kept(in: windows)
    } else {
      let front = windows.first { $0.isNormal && $0.reference.ownerPID == pid }
      target = (front?.reference, front == nil ? .unavailable : .uncertain)
    }
    guard let reference = target.0, windows.contains(where: { $0.reference == reference }) else {
      state = .unavailable
      return state
    }
    state = FocusState(window: reference, confidence: target.1)
    return state
  }

  private func kept(in windows: [CatalogWindow]) -> (WindowReference?, FocusConfidence) {
    guard let current = state.window, windows.contains(where: { $0.reference == current }) else {
      return (nil, .unavailable)
    }
    return (current, state.confidence)
  }
}
