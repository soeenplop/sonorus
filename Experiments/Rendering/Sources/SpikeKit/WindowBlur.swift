import AppKit
import Darwin

/// Stepless WindowServer blur behind a transparent window via the
/// UNDOCUMENTED SkyLight call `SLSSetWindowBackgroundBlurRadius` (alias
/// `CGSSetWindowBackgroundBlurRadius`). User decision (17.11.2026): private
/// API allowed for the blur, with native NSVisualEffectView as fallback.
/// Symbols are resolved with dlsym, so a missing symbol after a macOS update
/// is reported at runtime instead of failing to launch.
@MainActor
public enum WindowBlur {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias SetRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

  private static let handle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

  private static func symbol<T>(_ names: [String], as type: T.Type) -> T? {
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    for name in names {
      for source in [handle, defaultHandle] {
        if let pointer = dlsym(source, name) { return unsafeBitCast(pointer, to: type) }
      }
    }
    return nil
  }

  private static let mainConnection = symbol(
    ["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnection.self)
  private static let setRadius = symbol(
    ["SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius"], as: SetRadius.self)

  public static var isAvailable: Bool { mainConnection != nil && setRadius != nil }

  /// Applies `radius` points of blur behind `window`. Returns the CGError
  /// (0 = success), or nil when the private symbols are missing.
  @discardableResult
  public static func apply(radius: Int, to window: NSWindow) -> Int32? {
    guard let mainConnection, let setRadius, window.windowNumber > 0 else { return nil }
    return setRadius(mainConnection(), UInt32(window.windowNumber), Int32(max(0, radius)))
  }
}
