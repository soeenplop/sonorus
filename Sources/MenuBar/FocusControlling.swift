import Contracts
import Foundation

/// Actions the menu bar content triggers. The app implements this on its
/// composition object and pushes state back through `MenuBarViewModel.apply(_:)`.
@MainActor
public protocol FocusControlling: AnyObject {
  func setEnabled(_ isEnabled: Bool)
  func setScope(_ scope: EffectScope)
  /// Starts the direct selection. The app is expected to dismiss the popover.
  func startSelection(_ mode: SelectionMode)
  /// Applies the effects live without saving. Called for every slider change.
  func previewEffects(_ effects: EffectSettings)
  /// Persists the effects. Called debounced after the last change.
  func commitEffects(_ effects: EffectSettings)
  func removeException(_ window: WindowReference)
  func quit()
}
