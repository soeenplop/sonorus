import AppKit
import CoreGraphics

/// Conversion between AppKit global coordinates (bottom-left origin of the
/// primary screen, y up) and Quartz global coordinates (top-left, y down).
@MainActor
public enum Coordinates {
  /// Height of the screen whose AppKit frame origin is (0, 0).
  public static var primaryHeight: CGFloat {
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    return primary?.frame.height ?? 0
  }

  public static func quartz(fromAppKit rect: CGRect) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  public static func appKit(fromQuartz rect: CGRect) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  public static func appKit(fromQuartz point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }
}

public struct DisplayInfo: Sendable {
  public let displayID: CGDirectDisplayID
  public let name: String
  public let uuid: String
  public let appKitFrame: CGRect
  public let quartzBounds: CGRect
  public let scale: CGFloat
  public let pixelSize: CGSize
  public let isMain: Bool
  /// Height of the menu bar strip at the top (frame minus visibleFrame).
  public let menuBarInset: CGFloat

  /// Effect scope: the display without the menu bar strip. The Dock area stays
  /// inside; the Dock window sits above normal-level panels anyway.
  public var scopeAppKitFrame: CGRect {
    CGRect(
      x: appKitFrame.minX, y: appKitFrame.minY, width: appKitFrame.width,
      height: appKitFrame.height - menuBarInset)
  }

  public var scopeQuartzBounds: CGRect {
    CGRect(
      x: quartzBounds.minX, y: quartzBounds.minY + menuBarInset, width: quartzBounds.width,
      height: quartzBounds.height - menuBarInset)
  }

  public var description: String {
    String(
      format: "id=%u \"%@\" uuid=%@ quartz=%@ appKit=%@ scale=%.1f pixels=%.0fx%.0f%@",
      displayID, name, uuid, CGWin.format(quartzBounds), CGWin.format(appKitFrame), scale,
      pixelSize.width, pixelSize.height, isMain ? " main" : "")
  }
}

@MainActor
public enum Displays {
  public static func all() -> [DisplayInfo] {
    NSScreen.screens.map { screen in
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      let id = CGDirectDisplayID(number?.uint32Value ?? 0)
      let uuid =
        CGDisplayCreateUUIDFromDisplayID(id).map {
          CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        } ?? "?"
      let mode = CGDisplayCopyDisplayMode(id)
      return DisplayInfo(
        displayID: id, name: screen.localizedName, uuid: uuid, appKitFrame: screen.frame,
        quartzBounds: CGDisplayBounds(id), scale: screen.backingScaleFactor,
        pixelSize: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
        isMain: CGDisplayIsMain(id) != 0,
        menuBarInset: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }
  }
}
