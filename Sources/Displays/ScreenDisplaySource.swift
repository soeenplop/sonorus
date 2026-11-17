import AppKit
import Contracts
import CoreGraphics

/// Reads the connected displays. Injectable so identity and change detection
/// can be tested without real hardware.
@MainActor
public protocol DisplaySource: AnyObject {
  func displays() -> [DisplayDescriptor]
}

/// Live source: `NSScreen` for name and scale, CoreGraphics for identity and
/// Quartz bounds (`CGDisplayBounds` is already global, top-left, in points).
@MainActor
public final class ScreenDisplaySource: DisplaySource {
  public init() {}

  public func displays() -> [DisplayDescriptor] {
    NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { return nil }
      let id = CGDirectDisplayID(number.uint32Value)
      let bounds = CGDisplayBounds(id)
      let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
        CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
      }
      return DisplayDescriptor(
        runtimeID: id, uuid: uuid, vendorNumber: CGDisplayVendorNumber(id),
        modelNumber: CGDisplayModelNumber(id), serialNumber: CGDisplaySerialNumber(id),
        name: screen.localizedName,
        frame: ScreenRect(
          x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
        scale: screen.backingScaleFactor)
    }
  }
}
