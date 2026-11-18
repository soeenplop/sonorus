import Contracts
import Foundation

public enum ConfigurationStoreError: Error, Equatable, Sendable {
  /// A damaged file could not be moved aside. Loading stops so that a later
  /// save cannot replace the only copy of the user's data.
  case backupFailed(file: URL, reason: String)
  /// The file was written by a newer Sonorus. It is left untouched and saving
  /// is refused while it exists, so a downgrade cannot destroy newer settings.
  case newerSchemaVersion(file: URL, version: Int)
  /// The last load failed. Saving is refused until a load succeeds, so the
  /// unread file is never replaced.
  case loadFailed(file: URL)
}

/// Stores `FocusConfiguration` as versioned JSON in one directory, by default
/// `~/Library/Application Support/Sonorus`. Writes are atomic. A missing file
/// yields defaults. A damaged file is renamed to a timestamped backup next to
/// it before defaults are returned, so nothing is lost silently. A file with a
/// newer schema version is never moved or overwritten: load returns defaults
/// and reports the version, save throws while that file exists.
///
/// Regions with non-finite coordinates are dropped before saving.
///
/// Only `FocusConfiguration` is accepted: runtime window exceptions live in
/// `FocusSession` and therefore can never reach disk.
public actor FileConfigurationStore: ConfigurationStoring {
  public static let currentSchemaVersion = 1
  public static let fileName = "configuration.json"

  public nonisolated let directory: URL
  public nonisolated var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

  /// Backup created by the most recent load, for user-facing recovery notes.
  public private(set) var lastRecoveredBackup: URL?

  /// Newer schema version found by the most recent load, if any.
  public private(set) var lastNewerSchemaVersion: Int?

  private let now: @Sendable () -> Date
  private var lastLoadFailed = false

  public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.now = now
  }

  public init() throws {
    self.init(directory: try Self.defaultDirectory())
  }

  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    return support.appendingPathComponent("Sonorus", isDirectory: true)
  }

  public func load() async throws -> FocusConfiguration {
    lastRecoveredBackup = nil
    lastNewerSchemaVersion = nil
    lastLoadFailed = false
    do {
      return try loadOrRecover()
    } catch {
      lastLoadFailed = true
      throw error
    }
  }

  private func loadOrRecover() throws -> FocusConfiguration {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch CocoaError.fileReadNoSuchFile {
      return FocusConfiguration()
    }
    if let version = Self.newerSchemaVersion(in: data) {
      lastNewerSchemaVersion = version
      return FocusConfiguration()
    }
    if let configuration = Self.decode(data) { return configuration }
    lastRecoveredBackup = try moveAside(reason: "corrupt")
    return FocusConfiguration()
  }

  public func save(_ configuration: FocusConfiguration) async throws {
    if lastLoadFailed { throw ConfigurationStoreError.loadFailed(file: fileURL) }
    if let data = try? Data(contentsOf: fileURL), let version = Self.newerSchemaVersion(in: data) {
      throw ConfigurationStoreError.newerSchemaVersion(file: fileURL, version: version)
    }
    var sanitized = configuration
    sanitized.regions.removeAll { !Self.isFinite($0.rect) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      StoredConfiguration(schemaVersion: Self.currentSchemaVersion, configuration: sanitized))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  private static func isFinite(_ rect: NormalizedRect) -> Bool {
    rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
  }

  // MARK: - Decoding

  private struct StoredConfiguration: Codable {
    let schemaVersion: Int
    let configuration: FocusConfiguration
  }

  private struct SchemaProbe: Decodable {
    let schemaVersion: Int
  }

  private static func decode(_ data: Data) -> FocusConfiguration? {
    let decoder = JSONDecoder()
    guard let probe = try? decoder.decode(SchemaProbe.self, from: data),
      probe.schemaVersion == currentSchemaVersion
    else { return nil }
    return try? decoder.decode(StoredConfiguration.self, from: data).configuration
  }

  private static func newerSchemaVersion(in data: Data) -> Int? {
    guard let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
      probe.schemaVersion > currentSchemaVersion
    else { return nil }
    return probe.schemaVersion
  }

  // MARK: - Recovery

  private func moveAside(reason: String) throws -> URL {
    let stamp = Int(now().timeIntervalSince1970)
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let backup = directory.appendingPathComponent(
      "configuration.\(reason)-\(stamp)-\(suffix).json")
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
    } catch {
      throw ConfigurationStoreError.backupFailed(
        file: fileURL, reason: error.localizedDescription)
    }
    return backup
  }
}
