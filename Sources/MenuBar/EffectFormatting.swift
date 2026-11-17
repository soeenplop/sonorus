import Foundation

/// Display text for slider values. Fixed format so it is testable.
enum EffectFormatting {
  /// 0…1 as "50%".
  static func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  /// Seconds as "750 ms" below one second, otherwise "1.5 s".
  static func duration(_ seconds: Double) -> String {
    let milliseconds = Int((seconds * 1000).rounded())
    guard milliseconds >= 1000 else { return "\(milliseconds) ms" }
    var fraction = String(format: "%03d", milliseconds % 1000)
    while fraction.count > 1, fraction.hasSuffix("0") { fraction.removeLast() }
    return "\(milliseconds / 1000).\(fraction) s"
  }
}
