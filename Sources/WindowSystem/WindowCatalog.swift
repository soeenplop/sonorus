import Contracts

/// A snapshot window plus the raw window-server facts focus mapping needs.
struct CatalogWindow: Equatable, Sendable {
  let snapshot: WindowSnapshot
  let record: WindowRecord

  var reference: WindowReference { snapshot.reference }
  var isNormal: Bool { snapshot.level == 0 && !snapshot.isSystemUI }
}

/// Turns raw window lists into snapshot windows and owns window lifetimes.
///
/// A `WindowReference` lives as long as its window exists: windows that leave
/// the on-screen list (minimized, other Space, hidden app) keep their reference
/// while the window server still knows their ID and owner. Once an ID is gone,
/// or reappears with another owner, it receives a fresh generation from a
/// monotonic counter, so stale exceptions never match a reused window ID.
struct WindowCatalog {
  static let minimumAlpha = 0.05

  /// Owners whose windows are system surfaces (Dock, menu bar, Control Center,
  /// notifications, Stage Manager, Spotlight).
  static let systemBundleIDs: Set<String> = [
    "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
    "com.apple.systemuiserver", "com.apple.WindowManager", "com.apple.Spotlight",
    "com.apple.TextInputMenuAgent",
  ]
  /// The menu bar is owned by the window server process, which has no bundle.
  static let systemOwnerNames: Set<String> = ["Window Server"]

  let ownPID: Int32
  private(set) var references: [UInt32: WindowReference] = [:]
  private var nextGeneration: UInt64 = 1

  init(ownPID: Int32) {
    self.ownPID = ownPID
  }

  /// - Parameters:
  ///   - records: on-screen window list, front to back.
  ///   - existing: re-describes window IDs that left the on-screen list; only
  ///     windows that still exist are returned.
  mutating func update(
    records: [WindowRecord], existing: ([UInt32]) -> [WindowRecord],
    bundleID: (Int32) -> String?, displays: [ScreenRect], separateSpaces: Bool
  ) -> [CatalogWindow] {
    let foreign = records.filter { $0.ownerPID != ownPID && $0.isOnScreen }
    trackLifetimes(foreign, existing: existing)
    return foreign.compactMap { record in
      guard let reference = references[record.windowID],
        record.alpha.isFinite, record.alpha >= Self.minimumAlpha
      else { return nil }
      let bundle = bundleID(record.ownerPID)
      let isSystemUI = Self.isSystemUI(record, bundleID: bundle)
      if isSystemUI, record.layer > 1, displays.contains(where: { record.frame.contains($0) }) {
        // Transparent full-display hosts (e.g. Notification Center at layer
        // 21) sit above every effect surface and would only read as a sharp
        // full-screen system surface.
        return nil
      }
      let frame = Self.visibleFrame(
        record.frame, displays: displays, separateSpaces: separateSpaces)
      guard frame.isUsable else { return nil }
      return CatalogWindow(
        snapshot: WindowSnapshot(
          reference: reference, ownerBundleID: bundle, frame: frame, level: record.layer,
          isOnScreen: true, isSystemUI: isSystemUI),
        record: record)
    }
  }

  private mutating func trackLifetimes(
    _ records: [WindowRecord], existing: ([UInt32]) -> [WindowRecord]
  ) {
    var next: [UInt32: WindowReference] = [:]
    for record in records where next[record.windowID] == nil {
      if let known = references[record.windowID], known.ownerPID == record.ownerPID {
        next[record.windowID] = known
      } else {
        next[record.windowID] = WindowReference(
          windowID: record.windowID, ownerPID: record.ownerPID, generation: nextGeneration)
        nextGeneration += 1
      }
    }
    let vanished = references.keys.filter { next[$0] == nil }.sorted()
    if !vanished.isEmpty {
      for record in existing(vanished) {
        if let known = references[record.windowID], known.ownerPID == record.ownerPID,
          next[record.windowID] == nil
        {
          next[record.windowID] = known
        }
      }
    }
    references = next
  }

  static func isSystemUI(_ record: WindowRecord, bundleID: String?) -> Bool {
    if let bundleID, systemBundleIDs.contains(bundleID) { return true }
    if let owner = record.ownerName, systemOwnerNames.contains(owner) { return true }
    return false
  }

  /// With separate Spaces per display a window is only shown on the display
  /// holding most of it; the rest is clipped away. Windows outside every
  /// display keep their frame.
  static func visibleFrame(
    _ frame: ScreenRect, displays: [ScreenRect], separateSpaces: Bool
  ) -> ScreenRect {
    guard separateSpaces else { return frame }
    var best: ScreenRect?
    for display in displays {
      guard let overlap = frame.intersection(display) else { continue }
      if overlap.area > (best?.area ?? 0) { best = overlap }
    }
    return best ?? frame
  }
}
