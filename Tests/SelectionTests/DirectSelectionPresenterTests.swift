import Contracts
import TestSupport
import XCTest

@testable import Selection

/// Only paths that never create a window; the overlay itself is checked manually.
@MainActor
final class DirectSelectionPresenterTests: XCTestCase {

  func testRequestWithoutDisplaysIsCancelledWithoutPresentingAnything() async {
    let empty = DesktopSnapshot(
      revision: 1, displays: [], windows: [], focusedWindow: nil, focusConfidence: .unavailable)
    let draft = SelectionDraft(windows: [DesktopFixtures.focused])
    let outcome = await DirectSelectionPresenter(ownerPID: 1).select(
      SelectionRequest(mode: .windows, desktop: empty, draft: draft))
    XCTAssertEqual(outcome, .cancelled)
  }
}
