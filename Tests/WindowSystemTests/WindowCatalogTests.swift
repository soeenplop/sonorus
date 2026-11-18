import Contracts
import XCTest

@testable import WindowSystem

final class WindowListParserTests: XCTestCase {
  func testParsesEntriesInOrder() {
    let records = WindowListParser.parse([
      cgEntry(7, pid: 70, owner: "Editor", layer: 0, frame: rect(10, 20, 300, 200)),
      cgEntry(8, pid: 80, owner: "Dock", layer: 20, frame: rect(0, 850, 1440, 50), alpha: 0.5),
    ])
    XCTAssertEqual(
      records,
      [
        WindowRecord(
          windowID: 7, ownerPID: 70, ownerName: "Editor", layer: 0,
          frame: rect(10, 20, 300, 200)),
        WindowRecord(
          windowID: 8, ownerPID: 80, ownerName: "Dock", layer: 20, frame: rect(0, 850, 1440, 50),
          alpha: 0.5),
      ])
  }

  func testDropsMalformedEntriesAndDefaultsMissingValues() {
    var noBounds = cgEntry(1, pid: 1, frame: rect(0, 0, 10, 10))
    noBounds.removeValue(forKey: kCGWindowBounds as String)
    var noPID = cgEntry(2, pid: 1, frame: rect(0, 0, 10, 10))
    noPID.removeValue(forKey: kCGWindowOwnerPID as String)
    var defaults = cgEntry(3, pid: 1, frame: rect(0, 0, 10, 10))
    defaults.removeValue(forKey: kCGWindowAlpha as String)
    defaults.removeValue(forKey: kCGWindowLayer as String)
    let records = WindowListParser.parse([noBounds, noPID, defaults])
    XCTAssertEqual(records.map(\.windowID), [3])
    XCTAssertEqual(records[0].alpha, 1)
    XCTAssertEqual(records[0].layer, 0)
  }
}

final class WindowCatalogTests: XCTestCase {
  private let ownPID: Int32 = 999

  private func update(
    _ catalog: inout WindowCatalog, _ onScreen: [[String: Any]], hidden: [[String: Any]] = [],
    bundles: [Int32: String] = [:], displays: [ScreenRect] = [rect(0, 0, 1440, 900)],
    separateSpaces: Bool = false
  ) -> [CatalogWindow] {
    let all = WindowListParser.parse(onScreen + hidden)
    return catalog.update(
      records: WindowListParser.parse(onScreen),
      existing: { ids in all.filter { ids.contains($0.windowID) } },
      bundleID: { bundles[$0] }, displays: displays, separateSpaces: separateSpaces)
  }

  func testKeepsFrontToBackOrderAndExcludesOwnWindows() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: ownPID, layer: 3, frame: rect(0, 0, 1440, 900)),
        cgEntry(2, pid: 10, frame: rect(0, 0, 100, 100)),
        cgEntry(3, pid: 11, frame: rect(50, 50, 100, 100)),
        cgEntry(4, pid: ownPID, frame: rect(50, 50, 100, 100)),
        cgEntry(5, pid: 10, frame: rect(60, 60, 100, 100)),
      ])
    XCTAssertEqual(windows.map(\.reference.windowID), [2, 3, 5])
    XCTAssertTrue(windows.allSatisfy { $0.snapshot.isOnScreen })
  }

  func testOmitsNearlyTransparentWindows() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100), alpha: 0.04),
        cgEntry(2, pid: 10, frame: rect(0, 0, 100, 100), alpha: 0.05),
        cgEntry(3, pid: 10, frame: rect(0, 0, 100, 100), alpha: 0),
      ])
    XCTAssertEqual(windows.map(\.reference.windowID), [2])
  }

  func testFadingWindowKeepsItsGeneration() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let visible = update(&catalog, [cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))])
    _ = update(&catalog, [cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100), alpha: 0.01)])
    let back = update(&catalog, [cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))])
    XCTAssertEqual(back[0].reference, visible[0].reference)
  }

  func testClassifiesSystemSurfaces() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: 1, owner: "Window Server", layer: 24, frame: rect(0, 0, 1440, 30)),
        cgEntry(2, pid: 2, owner: "Dock", layer: 20, frame: rect(0, 850, 1440, 50)),
        cgEntry(3, pid: 3, owner: "Control Center", layer: 25, frame: rect(1200, 0, 30, 24)),
        cgEntry(4, pid: 4, owner: "Notification Center", layer: 23, frame: rect(1000, 40, 400, 90)),
        cgEntry(5, pid: 5, owner: "Editor", layer: 0, frame: rect(100, 100, 400, 300)),
        cgEntry(6, pid: 5, owner: "Editor", layer: 3, frame: rect(100, 100, 200, 300)),
      ],
      bundles: [
        2: "com.apple.dock", 3: "com.apple.controlcenter", 4: "com.apple.notificationcenterui",
        5: "fixture.editor",
      ])
    XCTAssertEqual(windows.map(\.snapshot.isSystemUI), [true, true, true, true, false, false])
    XCTAssertEqual(windows.map(\.snapshot.level), [24, 20, 25, 23, 0, 3])
    XCTAssertEqual(windows[4].snapshot.ownerBundleID, "fixture.editor")
    XCTAssertNil(windows[0].snapshot.ownerBundleID)
  }

  func testDropsTransparentFullDisplaySystemHosts() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: 4, layer: 21, frame: rect(0, 0, 1440, 900)),
        cgEntry(2, pid: 4, layer: 23, frame: rect(1000, 40, 400, 90)),
        cgEntry(3, pid: 4, layer: -2_147_483_601, frame: rect(20, 50, 180, 180)),
        cgEntry(4, pid: 5, layer: 0, frame: rect(0, 0, 1440, 900)),
      ],
      bundles: [4: "com.apple.notificationcenterui"])
    XCTAssertEqual(windows.map(\.reference.windowID), [2, 3, 4])
  }

  func testGenerationsSurviveHidingButNotDisappearance() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let a = cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))
    let b = cgEntry(2, pid: 10, frame: rect(0, 0, 100, 100))
    let first = update(&catalog, [a, b])
    let refA = first[0].reference
    let refB = first[1].reference
    XCTAssertNotEqual(refA.generation, refB.generation)

    // Unchanged: same references.
    XCTAssertEqual(update(&catalog, [a, b]).map(\.reference), [refA, refB])

    // A minimized (still exists), B closed.
    XCTAssertEqual(
      update(
        &catalog, [], hidden: [cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100), onScreen: false)]
      )
      .count, 0)
    let again = update(&catalog, [a, b])
    XCTAssertEqual(
      again[0].reference, refA, "a window that only left the screen keeps its reference")
    XCTAssertEqual(again[1].reference.windowID, 2)
    XCTAssertGreaterThan(again[1].reference.generation, refB.generation)
  }

  func testAlreadyHiddenWindowsAreOnlyCheckedOnRequest() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let a = cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))
    var described: [[UInt32]] = []
    func update(_ onScreen: [[String: Any]], checkHidden: Bool) {
      _ = catalog.update(
        records: WindowListParser.parse(onScreen),
        existing: { ids in
          described.append(ids)
          return []
        },
        bundleID: { _ in nil }, displays: [rect(0, 0, 1440, 900)], separateSpaces: false,
        checkHidden: checkHidden)
    }
    update([a], checkHidden: false)
    update([], checkHidden: false)
    XCTAssertEqual(described, [[1]], "a window that just left the screen is checked at once")

    described = []
    let b = cgEntry(2, pid: 10, frame: rect(0, 0, 100, 100))
    update([a, b], checkHidden: false)
    update([b], checkHidden: false)
    update([b], checkHidden: false)
    XCTAssertEqual(described, [[1]])
    XCTAssertNil(catalog.references[1], "the closed window is dropped")
  }

  func testHiddenWindowKeepsReferenceUntilChecked() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let a = cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))
    let hiddenA = cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100), onScreen: false)
    let ref = update(&catalog, [a])[0].reference
    _ = update(&catalog, [], hidden: [hiddenA])
    _ = catalog.update(
      records: [], existing: { _ in [] }, bundleID: { _ in nil },
      displays: [rect(0, 0, 1440, 900)], separateSpaces: false, checkHidden: false)
    XCTAssertEqual(catalog.references[1], ref)
    _ = update(&catalog, [])
    XCTAssertNil(catalog.references[1], "closed while hidden, dropped at the next check")
  }

  func testReusedIDWithAnotherOwnerGetsNewGeneration() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let old = update(&catalog, [cgEntry(1, pid: 10, frame: rect(0, 0, 100, 100))])[0].reference
    let reused = update(&catalog, [cgEntry(1, pid: 11, frame: rect(0, 0, 100, 100))])[0].reference
    XCTAssertEqual(reused.windowID, old.windowID)
    XCTAssertEqual(reused.ownerPID, 11)
    XCTAssertGreaterThan(reused.generation, old.generation)
  }

  func testVisibleFrameIsUnchangedWithoutSeparateSpaces() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let spanning = rect(-300, 100, 800, 400)
    let windows = update(
      &catalog, [cgEntry(1, pid: 10, frame: spanning)],
      displays: [rect(0, 0, 1440, 900), rect(-1920, -100, 1920, 1080)])
    XCTAssertEqual(windows[0].snapshot.frame, spanning)
  }

  func testVisibleFrameClipsToDisplayWithLargestOverlap() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let displays = [rect(0, 0, 1440, 900), rect(-1920, -100, 1920, 1080)]
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: 10, frame: rect(-300, 100, 800, 400)),
        cgEntry(2, pid: 10, frame: rect(-600, 100, 800, 400)),
        cgEntry(3, pid: 10, frame: rect(5000, 5000, 100, 100)),
      ],
      displays: displays, separateSpaces: true)
    XCTAssertEqual(windows[0].snapshot.frame, rect(0, 100, 500, 400))
    XCTAssertEqual(windows[1].snapshot.frame, rect(-600, 100, 600, 400))
    XCTAssertEqual(windows[2].snapshot.frame, rect(5000, 5000, 100, 100))
    XCTAssertEqual(windows[0].record.frame, rect(-300, 100, 800, 400), "raw frame kept for focus")
  }

  func testDropsWindowsWithoutUsableFrame() {
    var catalog = WindowCatalog(ownPID: ownPID)
    let windows = update(
      &catalog,
      [
        cgEntry(1, pid: 10, frame: rect(0, 0, 0, 20)),
        cgEntry(2, pid: 10, frame: rect(0, 0, 20, 20)),
      ])
    XCTAssertEqual(windows.map(\.reference.windowID), [2])
  }
}
