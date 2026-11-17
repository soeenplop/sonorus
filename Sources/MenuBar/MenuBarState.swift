import Contracts
import Foundation

/// A connected display in the order the app wants it listed.
public struct MenuBarDisplay: Identifiable, Equatable, Sendable {
  public let id: DisplayID
  public let name: String

  public init(id: DisplayID, name: String) {
    self.id = id
    self.name = name
  }
}

/// A session-only "keep sharp" window, named after its application.
public struct MenuBarException: Identifiable, Equatable, Sendable {
  public let reference: WindowReference
  public let appName: String?

  public var id: WindowReference { reference }

  public init(reference: WindowReference, appName: String? = nil) {
    self.reference = reference
    self.appName = Self.nonEmpty(appName)
  }

  public var displayName: String { appName ?? "Unknown window" }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// Everything the popover shows, as plain values.
public struct MenuBarState: Equatable, Sendable {
  public var configuration: FocusConfiguration
  public var exceptions: [MenuBarException]
  /// Connected displays. Region and display selections of other displays are paused.
  public var displays: [MenuBarDisplay]
  /// True when the renderer lacks the adjustable blur and only approximates it.
  public var usesFallbackBlur: Bool

  public init(
    configuration: FocusConfiguration = FocusConfiguration(),
    exceptions: [MenuBarException] = [], displays: [MenuBarDisplay] = [],
    usesFallbackBlur: Bool = false
  ) {
    self.configuration = configuration
    self.exceptions = exceptions
    self.displays = displays
    self.usesFallbackBlur = usesFallbackBlur
  }
}
