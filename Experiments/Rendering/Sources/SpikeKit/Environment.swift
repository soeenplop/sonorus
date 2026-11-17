import AppKit
import CoreGraphics

@MainActor
public enum SpikeEnvironment {
  /// Prints permissions and accessibility display options without prompting.
  /// - Screen Recording preflight: https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()
  /// - Reduce Transparency: https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency
  public static func report() {
    let workspace = NSWorkspace.shared
    Log.observed("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    Log.observed(
      "Accessibility trusted (AXIsProcessTrusted): \(FocusResolver.isAccessibilityTrusted)")
    Log.observed(
      "Screen Recording preflight (CGPreflightScreenCaptureAccess): \(CGPreflightScreenCaptureAccess())"
    )
    Log.observed(
      "reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency) "
        + "reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion) "
        + "increaseContrast=\(workspace.accessibilityDisplayShouldIncreaseContrast)")
    for display in Displays.all() { Log.observed("display \(display.description)") }
    Log.observed("frontmost app: \(workspace.frontmostApplication?.localizedName ?? "nil")")
  }
}
