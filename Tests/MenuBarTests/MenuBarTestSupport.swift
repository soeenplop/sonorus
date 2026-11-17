import Contracts
import Foundation

@testable import MenuBar

@MainActor
final class RecordingController: FocusControlling {
  enum Call: Equatable {
    case setEnabled(Bool)
    case setScope(EffectScope)
    case startSelection(SelectionMode)
    case preview(EffectSettings)
    case commit(EffectSettings)
    case removeException(WindowReference)
    case quit
  }

  private(set) var calls: [Call] = []

  func setEnabled(_ isEnabled: Bool) { calls.append(.setEnabled(isEnabled)) }
  func setScope(_ scope: EffectScope) { calls.append(.setScope(scope)) }
  func startSelection(_ mode: SelectionMode) { calls.append(.startSelection(mode)) }
  func previewEffects(_ effects: EffectSettings) { calls.append(.preview(effects)) }
  func commitEffects(_ effects: EffectSettings) { calls.append(.commit(effects)) }
  func removeException(_ window: WindowReference) { calls.append(.removeException(window)) }
  func quit() { calls.append(.quit) }

  var commits: [EffectSettings] {
    calls.compactMap { if case .commit(let effects) = $0 { effects } else { nil } }
  }
}

/// Stands in for the debounce wait: sleepers suspend until `fire()`.
final class ManualSleeper: @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [UUID: Continuation] = [:]

  var waiterCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return waiters.count
  }

  func sleep(_ duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: Continuation) in
        register(continuation, id: id)
      }
    } onCancel: {
      cancel(id: id)
    }
  }

  private typealias Continuation = CheckedContinuation<Void, any Error>

  private func register(_ continuation: Continuation, id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    if Task.isCancelled {
      continuation.resume(throwing: CancellationError())
    } else {
      waiters[id] = continuation
    }
  }

  private func cancel(id: UUID) {
    lock.lock()
    let continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }

  /// Lets the debounce wait of every current sleeper elapse.
  func fire() {
    lock.lock()
    let continuations = Array(waiters.values)
    waiters.removeAll()
    lock.unlock()
    for continuation in continuations { continuation.resume() }
  }

  /// Waits until a sleeper has started waiting.
  func waitForSleeper() async {
    while waiterCount == 0 { await Task.yield() }
  }
}
