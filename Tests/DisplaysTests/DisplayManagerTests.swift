import AppKit
import Contracts
import XCTest

@testable import Displays

@MainActor
final class FakeDisplaySource: DisplaySource {
  var descriptors: [DisplayDescriptor]
  private(set) var reads = 0

  init(_ descriptors: [DisplayDescriptor]) { self.descriptors = descriptors }

  func displays() -> [DisplayDescriptor] {
    reads += 1
    return descriptors
  }
}

private let builtIn = DisplayDescriptor(
  runtimeID: 1, uuid: "37d8832a-2d66-02ca-b9f7-8f30a301b230", vendorNumber: 1552,
  modelNumber: 41_234, serialNumber: 0, name: "Built-in",
  frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)

private let external = DisplayDescriptor(
  runtimeID: 3, uuid: "5E1C0F9A-0000-0000-0000-000000000001", vendorNumber: 4268,
  modelNumber: 16_711, serialNumber: 1, name: "External",
  frame: ScreenRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1)

@MainActor
final class DisplayIdentityTests: XCTestCase {
  func testUUIDIsPersistentIdentityAndRuntimeIDIsKept() {
    let snapshot = DisplayIdentity.snapshots(for: [builtIn])[0]
    XCTAssertEqual(snapshot.id, DisplayID(rawValue: "uuid:37D8832A-2D66-02CA-B9F7-8F30A301B230"))
    XCTAssertEqual(snapshot.runtimeID, 1)
    XCTAssertEqual(snapshot.frame, builtIn.frame)
    XCTAssertEqual(snapshot.scale, 2)
    XCTAssertEqual(snapshot.name, "Built-in")
  }

  func testSameDisplayKeepsIdentityAcrossRuntimeIDs() {
    var reconnected = external
    reconnected.runtimeID = 77
    reconnected.frame = ScreenRect(x: 1512, y: 0, width: 1920, height: 1080)
    XCTAssertEqual(DisplayIdentity.id(for: reconnected), DisplayIdentity.id(for: external))
  }

  func testFallsBackToVendorModelSerial() {
    var noUUID = external
    noUUID.uuid = nil
    XCTAssertEqual(DisplayIdentity.id(for: noUUID), DisplayID(rawValue: "edid:4268-16711-1"))
    noUUID.uuid = "00000000-0000-0000-0000-000000000000"
    XCTAssertEqual(DisplayIdentity.id(for: noUUID), DisplayID(rawValue: "edid:4268-16711-1"))
  }

  func testIdenticalMonitorsShareAnAmbiguousIDButKeepDistinctRuntimeIDs() {
    var twinA = external
    twinA.uuid = nil
    twinA.serialNumber = 0
    var twinB = twinA
    twinB.runtimeID = 4
    twinB.frame = ScreenRect(x: 1512, y: 0, width: 1920, height: 1080)
    let snapshots = DisplayIdentity.snapshots(for: [twinB, builtIn, twinA])
    XCTAssertEqual(snapshots[1].id, snapshots[2].id)
    XCTAssertNotEqual(snapshots[1].runtimeID, snapshots[2].runtimeID)
  }

  func testOrderIsPrimaryFirstThenSpatial() {
    let snapshots = DisplayIdentity.snapshots(for: [external, builtIn])
    XCTAssertEqual(snapshots.map(\.runtimeID), [1, 3])
  }

  func testUnusableFramesAndScalesAreSanitized() {
    var broken = external
    broken.frame = ScreenRect(x: 0, y: 0, width: 0, height: 0)
    var badScale = builtIn
    badScale.scale = .nan
    let snapshots = DisplayIdentity.snapshots(for: [broken, badScale])
    XCTAssertEqual(snapshots.map(\.runtimeID), [1])
    XCTAssertEqual(snapshots[0].scale, 1)
  }
}

@MainActor
final class DisplayManagerTests: XCTestCase {
  func testStoppedManagerReadsLive() {
    let source = FakeDisplaySource([builtIn])
    let manager = DisplayManager(source: source, notificationCenter: NotificationCenter())
    XCTAssertEqual(manager.currentDisplays().count, 1)
    source.descriptors = [builtIn, external]
    XCTAssertEqual(manager.currentDisplays().count, 2)
  }

  func testStartedManagerCachesUntilNotification() {
    let center = NotificationCenter()
    let source = FakeDisplaySource([builtIn])
    let manager = DisplayManager(source: source, notificationCenter: center)
    manager.start()
    source.descriptors = [builtIn, external]
    XCTAssertEqual(manager.currentDisplays().count, 1)
    center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    XCTAssertEqual(manager.currentDisplays().count, 2)
    manager.stop()
  }

  func testChangesYieldOnlyRealChanges() async {
    let source = FakeDisplaySource([builtIn])
    let manager = DisplayManager(source: source, notificationCenter: NotificationCenter())
    manager.start()
    var iterator = manager.changes().makeAsyncIterator()

    XCTAssertFalse(manager.refresh(), "unchanged parameters must not emit")
    var moved = external
    moved.frame.x = 1512
    moved.frame.y = 0
    source.descriptors = [builtIn, moved]
    XCTAssertTrue(manager.refresh())
    let first = await iterator.next()
    XCTAssertEqual(first?.map(\.runtimeID), [1, 3])

    XCTAssertFalse(manager.refresh())
    var rescaled = builtIn
    rescaled.scale = 1
    source.descriptors = [rescaled, moved]
    XCTAssertTrue(manager.refresh())
    let second = await iterator.next()
    XCTAssertEqual(second?.first?.scale, 1)

    manager.stop()
    let end = await iterator.next()
    XCTAssertNil(end)
  }

  func testStopRemovesObserver() {
    let center = NotificationCenter()
    let source = FakeDisplaySource([builtIn])
    let manager = DisplayManager(source: source, notificationCenter: center)
    manager.start()
    manager.stop()
    let reads = source.reads
    center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    XCTAssertEqual(source.reads, reads)
  }
}
