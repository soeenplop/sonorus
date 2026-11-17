import AppKit
import Contracts
import XCTest

@testable import MenuBar

final class StatusIconSymbolTests: XCTestCase {
  func testEverySymbolExistsOnThisSystem() {
    for enabled in [true, false] {
      let icon = StatusIcon.make(isEnabled: enabled)
      XCTAssertNotNil(
        NSImage(
          systemSymbolName: icon.symbolName, accessibilityDescription: icon.accessibilityLabel),
        icon.symbolName)
    }
  }
}
