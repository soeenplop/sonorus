import Contracts
import Foundation

/// Raw facts about one connected display as read from AppKit and CoreGraphics.
/// `frame` is in global Quartz points (primary display top-left, y down).
public struct DisplayDescriptor: Equatable, Sendable {
  public var runtimeID: UInt32
  /// `CGDisplayCreateUUIDFromDisplayID`; nil when CoreGraphics returns none.
  public var uuid: String?
  public var vendorNumber: UInt32
  public var modelNumber: UInt32
  public var serialNumber: UInt32
  public var name: String
  public var frame: ScreenRect
  public var scale: Double

  public init(
    runtimeID: UInt32, uuid: String?, vendorNumber: UInt32 = 0, modelNumber: UInt32 = 0,
    serialNumber: UInt32 = 0, name: String, frame: ScreenRect, scale: Double
  ) {
    self.runtimeID = runtimeID
    self.uuid = uuid
    self.vendorNumber = vendorNumber
    self.modelNumber = modelNumber
    self.serialNumber = serialNumber
    self.name = name
    self.frame = frame
    self.scale = scale
  }
}

/// Persistent display identity.
///
/// The CoreGraphics UUID is stable across launches and reconnects; it is
/// derived from EDID data, so identical monitors without serial numbers can
/// share it. Such displays are deliberately NOT disambiguated by position or
/// connection order: the shared `DisplayID` is the ambiguity report that the
/// rules and selection act on (pause and ask), instead of silently attaching
/// rules to the wrong monitor. Without a UUID the vendor/model/serial triple is
/// used, which carries the same caveat.
enum DisplayIdentity {
  private static let nullUUID = "00000000-0000-0000-0000-000000000000"

  static func id(for descriptor: DisplayDescriptor) -> DisplayID {
    if let uuid = descriptor.uuid?.uppercased(), !uuid.isEmpty, uuid != nullUUID {
      return DisplayID(rawValue: "uuid:\(uuid)")
    }
    return DisplayID(
      rawValue:
        "edid:\(descriptor.vendorNumber)-\(descriptor.modelNumber)-\(descriptor.serialNumber)")
  }

  /// Primary display first (Quartz origin), then left to right, top to bottom,
  /// so equal desktops always produce equal lists.
  static func snapshots(for descriptors: [DisplayDescriptor]) -> [DisplaySnapshot] {
    descriptors
      .filter { $0.frame.isUsable }
      .sorted { lhs, rhs in
        let lhsPrimary = lhs.frame.x == 0 && lhs.frame.y == 0
        let rhsPrimary = rhs.frame.x == 0 && rhs.frame.y == 0
        if lhsPrimary != rhsPrimary { return lhsPrimary }
        if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
        if lhs.frame.y != rhs.frame.y { return lhs.frame.y < rhs.frame.y }
        return lhs.runtimeID < rhs.runtimeID
      }
      .map {
        DisplaySnapshot(
          id: id(for: $0), runtimeID: $0.runtimeID, name: $0.name, frame: $0.frame,
          scale: $0.scale > 0 && $0.scale.isFinite ? $0.scale : 1)
      }
  }
}
