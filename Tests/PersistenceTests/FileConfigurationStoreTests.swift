import Contracts
import Foundation
import XCTest

@testable import Persistence

final class FileConfigurationStoreTests: XCTestCase {
  private var root: URL!
  private var directory: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SonorusPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    directory = root.appendingPathComponent("nested/Sonorus", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private let display = DisplayID(rawValue: "display-uuid-1")

  private let sample = FocusConfiguration(
    isEnabled: true, scope: .regions,
    regions: [
      FocusRegion(
        displayID: DisplayID(rawValue: "display-uuid-1"),
        rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
      FocusRegion(
        displayID: DisplayID(rawValue: "display-uuid-2"),
        rect: NormalizedRect(x: 0.15, y: 0.25, width: 0.5, height: 0.5), isEnabled: false),
    ],
    effects: EffectSettings(blur: 0.8, backgroundBrightness: 0.3, transitionDuration: 0.25))

  private func makeStore() -> FileConfigurationStore {
    FileConfigurationStore(
      directory: directory, now: { Date(timeIntervalSince1970: 1_700_000_000) })
  }

  private func contents() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  // MARK: - Round trip

  func testMissingFileLoadsDefaultsWithoutWriting() async throws {
    let store = makeStore()
    let loaded = try await store.load()
    XCTAssertEqual(loaded, FocusConfiguration())
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    let backup = await store.lastRecoveredBackup
    XCTAssertNil(backup)
  }

  func testRoundTripCreatesDirectoryAndPreservesEveryScope() async throws {
    let scopes: [EffectScope] = [
      .allDisplays, .displays([display, DisplayID(rawValue: "other")]), .regions,
    ]
    for scope in scopes {
      var configuration = sample
      configuration.scope = scope
      try await makeStore().save(configuration)
      let loaded = try await makeStore().load()
      XCTAssertEqual(loaded, configuration)
    }
    XCTAssertEqual(try contents(), [FileConfigurationStore.fileName])
  }

  func testStoredFileIsVersionedAndContainsNoWindowExceptions() async throws {
    let session = FocusSession(
      configuration: sample,
      exceptions: [WindowReference(windowID: 4242, ownerPID: 777, generation: 9)])
    let store = makeStore()
    try await store.save(session.configuration)

    let data = try Data(contentsOf: store.fileURL)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["schemaVersion"] as? Int, FileConfigurationStore.currentSchemaVersion)
    XCTAssertNotNil(object["configuration"])
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    for forbidden in ["exceptions", "windowID", "ownerPID", "generation", "4242"] {
      XCTAssertFalse(text.contains(forbidden), forbidden)
    }
  }

  func testOverwriteReplacesPreviousConfiguration() async throws {
    let store = makeStore()
    try await store.save(sample)
    var changed = sample
    changed.isEnabled = false
    changed.regions.removeFirst()
    try await store.save(changed)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, changed)
  }

  func testOutOfRangeEffectValuesAreClampedOnLoad() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
      {"schemaVersion":1,"configuration":{"isEnabled":true,"scope":{"allDisplays":{}},
      "regions":[],"effects":{"blur":7,"backgroundBrightness":-1,"transitionDuration":9}}}
      """
    let store = makeStore()
    try Data(json.utf8).write(to: store.fileURL)
    let loaded = try await store.load()
    XCTAssertTrue(loaded.isEnabled)
    XCTAssertEqual(loaded.effects.blur, 1)
    XCTAssertEqual(loaded.effects.backgroundBrightness, 0)
    XCTAssertEqual(loaded.effects.transitionDuration, 1.5)
  }

  // MARK: - Corruption and recovery

  func testCorruptFileFallsBackToDefaultsAndKeepsBackup() async throws {
    let garbage = Data("{not json".utf8)
    try await assertRecovery(from: garbage, reason: "corrupt")
  }

  func testWrongShapeFallsBackToDefaultsAndKeepsBackup() async throws {
    let wrongShape = Data(#"{"schemaVersion":1,"configuration":{"isEnabled":"yes"}}"#.utf8)
    try await assertRecovery(from: wrongShape, reason: "corrupt")
  }

  func testMissingSchemaVersionIsTreatedAsCorrupt() async throws {
    let unversioned = try JSONEncoder().encode(sample)
    try await assertRecovery(from: unversioned, reason: "corrupt")
  }

  func testNewerSchemaFileIsPreservedAndBlocksSaving() async throws {
    let future = Data(#"{"schemaVersion":99,"configuration":{"anything":true}}"#.utf8)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore()
    try future.write(to: store.fileURL)

    let loaded = try await store.load()
    XCTAssertEqual(loaded, FocusConfiguration())
    let version = await store.lastNewerSchemaVersion
    XCTAssertEqual(version, 99)
    let recovered = await store.lastRecoveredBackup
    XCTAssertNil(recovered)

    do {
      try await store.save(sample)
      XCTFail("expected newerSchemaVersion")
    } catch let error as ConfigurationStoreError {
      XCTAssertEqual(error, .newerSchemaVersion(file: store.fileURL, version: 99))
    }
    // A fresh store without a prior load refuses as well.
    do {
      try await makeStore().save(sample)
      XCTFail("expected newerSchemaVersion")
    } catch ConfigurationStoreError.newerSchemaVersion {}
    XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    XCTAssertEqual(try contents(), [FileConfigurationStore.fileName])

    try FileManager.default.removeItem(at: store.fileURL)
    try await store.save(sample)
    let reloaded = try await store.load()
    XCTAssertEqual(reloaded, sample)
    let cleared = await store.lastNewerSchemaVersion
    XCTAssertNil(cleared)
  }

  func testOlderSchemaVersionIsBackedUpAsCorrupt() async throws {
    let past = Data(#"{"schemaVersion":0,"configuration":{}}"#.utf8)
    try await assertRecovery(from: past, reason: "corrupt")
  }

  func testRecoveryKeepsBackupAcrossLaterSavesAndLoads() async throws {
    let garbage = Data([0xFF, 0x00, 0x13])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore()
    try garbage.write(to: store.fileURL)

    _ = try await store.load()
    try await store.save(sample)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, sample)
    let recovered = await store.lastRecoveredBackup
    XCTAssertNil(recovered, "a healthy load reports no recovery")

    let backups = try contents().filter { $0 != FileConfigurationStore.fileName }
    XCTAssertEqual(backups.count, 1)
    let backup = directory.appendingPathComponent(try XCTUnwrap(backups.first))
    XCTAssertEqual(try Data(contentsOf: backup), garbage)
  }

  func testFailedBackupStopsLoadInsteadOfReturningDefaults() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore()
    try Data("broken".utf8).write(to: store.fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    do {
      _ = try await store.load()
      XCTFail("expected backupFailed")
    } catch let error as ConfigurationStoreError {
      guard case .backupFailed = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("broken".utf8))
  }

  func testNonFiniteRegionsAreDroppedBeforeSaving() async throws {
    let store = makeStore()
    var invalid = sample
    invalid.regions[0].rect.x = .nan
    invalid.regions[1].rect.height = .infinity
    invalid.regions.append(
      FocusRegion(displayID: display, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)))
    try await store.save(invalid)
    let loaded = try await store.load()
    XCTAssertEqual(loaded.regions, [invalid.regions[2]])
  }

  func testFailedSaveLeavesPreviousFileIntact() async throws {
    let store = makeStore()
    try await store.save(sample)
    let before = try Data(contentsOf: store.fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    var changed = sample
    changed.isEnabled = false
    do {
      try await store.save(changed)
      XCTFail("write into a read-only directory must fail")
    } catch {}

    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    XCTAssertEqual(try contents(), [FileConfigurationStore.fileName])
  }

  func testConcurrentSavesLeaveOneValidFile() async throws {
    let store = makeStore()
    let base = sample
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<25 {
        group.addTask {
          var configuration = base
          configuration.regions[0].rect.x = Double(index) / 100
          try await store.save(configuration)
        }
      }
      try await group.waitForAll()
    }
    let loaded = try await store.load()
    XCTAssertEqual(loaded.regions.count, 2)
    let recovered = await store.lastRecoveredBackup
    XCTAssertNil(recovered)
    XCTAssertEqual(try contents(), [FileConfigurationStore.fileName])
  }

  func testDefaultDirectoryIsApplicationSupportSonorus() throws {
    let url = try FileConfigurationStore.defaultDirectory()
    XCTAssertEqual(url.lastPathComponent, "Sonorus")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
  }

  // MARK: - Helpers

  private func assertRecovery(
    from data: Data, reason: String, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore()
    try data.write(to: store.fileURL)

    let loaded = try await store.load()
    XCTAssertEqual(loaded, FocusConfiguration(), file: file, line: line)
    let recovered = await store.lastRecoveredBackup
    let backup = try XCTUnwrap(recovered, file: file, line: line)
    XCTAssertTrue(
      backup.lastPathComponent.hasPrefix("configuration.\(reason)-1700000000-"),
      backup.lastPathComponent, file: file, line: line)
    XCTAssertEqual(try Data(contentsOf: backup), data, file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: store.fileURL.path), file: file, line: line)
  }
}
