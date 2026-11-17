import Contracts

/// Menu bar icon. Each state has its own symbol shape, so the state never
/// depends on colour alone (the icon is a template image in the menu bar).
public struct StatusIcon: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// Focus effect is on and working.
    case active
    /// Focus effect is off.
    case off
  }

  public let kind: Kind
  public let symbolName: String
  public let accessibilityLabel: String

  /// Mapping: active `viewfinder.circle.fill`, off `viewfinder`.
  public static func make(isEnabled: Bool) -> StatusIcon {
    if isEnabled {
      return StatusIcon(
        kind: .active, symbolName: "viewfinder.circle.fill",
        accessibilityLabel: "Sonorus, focus on")
    }
    return StatusIcon(
      kind: .off, symbolName: "viewfinder", accessibilityLabel: "Sonorus, focus off")
  }
}
