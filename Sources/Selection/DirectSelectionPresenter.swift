import AppKit
import Contracts

/// Screenshot-style direct selection on the desktop: one overlay panel per
/// display with window/display hover, region drawing and a compact toolbar.
///
/// Work happens on a copy of the draft; the caller only sees `.confirmed(draft)`
/// after Enter or the confirm button. Esc, the cancel button, a display change
/// and `cancel()` all end with `.cancelled`.
@MainActor
public final class DirectSelectionPresenter: SelectionPresenting {
  private let ownerPID: Int32
  private var session: SelectionSession?
  private var continuation: CheckedContinuation<SelectionOutcome, Never>?

  /// - Parameter ownerPID: windows of this process are never selectable.
  public init(ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
    self.ownerPID = ownerPID
  }

  public func select(_ request: SelectionRequest) async -> SelectionOutcome {
    cancel()
    guard !request.desktop.displays.isEmpty else { return .cancelled }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      let session = SelectionSession(request: request, excludedOwnerPIDs: [ownerPID]) {
        [weak self] outcome in
        self?.finish(outcome)
      }
      self.session = session
      session.present()
    }
  }

  /// Tears down all overlays immediately; a pending `select` returns `.cancelled`.
  public func cancel() {
    finish(.cancelled)
  }

  private func finish(_ outcome: SelectionOutcome) {
    let session = session
    let continuation = continuation
    self.session = nil
    self.continuation = nil
    session?.tearDown()
    continuation?.resume(returning: outcome)
  }
}
