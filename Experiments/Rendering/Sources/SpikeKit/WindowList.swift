import AppKit
import CoreGraphics

/// One CGWindowList entry. Bounds are global Quartz points (top-left origin of
/// the primary display, y down) exactly like `Contracts.ScreenRect`.
public struct CGWin: Equatable, Sendable {
  public let id: CGWindowID
  public let pid: pid_t
  public let owner: String
  public let bundleID: String?
  /// `kCGWindowName` is only populated when the caller holds Screen Recording.
  public let name: String?
  public let layer: Int
  public let bounds: CGRect
  public let alpha: Double
  public let isOnScreen: Bool
  public let sharingState: Int

  /// Titles are private data; spikes print only their length unless `--titles` is passed.
  nonisolated(unsafe) public static var showTitles = false

  public static let normalLayer = 0

  public init(
    id: CGWindowID, pid: pid_t, owner: String, name: String? = nil, layer: Int = 0,
    bounds: CGRect, alpha: Double = 1, isOnScreen: Bool = true, sharingState: Int = 1,
    bundleID: String? = nil
  ) {
    self.id = id
    self.pid = pid
    self.owner = owner
    self.bundleID = bundleID
    self.name = name
    self.layer = layer
    self.bounds = bounds
    self.alpha = alpha
    self.isOnScreen = isOnScreen
    self.sharingState = sharingState
  }

  /// Public process identity plus desktop level, never a localized title or a
  /// blanket exemption for Notification Center banners at elevated levels.
  public var isDesktopWidget: Bool {
    layer < Self.normalLayer && bundleID == "com.apple.notificationcenterui"
  }

  /// Desktop/window-list elements are intentionally outside sharp-surface masking.
  public var isMaskEligible: Bool {
    isOnScreen && alpha.isFinite && alpha > 0.05
      && layer > Int(CGWindowLevelForKey(.desktopIconWindow))
  }

  public var isNormalLevel: Bool { layer == Self.normalLayer }

  public var shortDescription: String {
    let title =
      name.map { Self.showTitles ? "\"\($0)\"" : "<title \($0.count) chars>" }
      ?? "<no title>"
    return
      "#\(id) pid=\(pid) \(owner) layer=\(layer) alpha=\(alpha) \(title) \(Self.format(bounds))"
  }

  public static func format(_ rect: CGRect) -> String {
    String(
      format: "(x=%.0f y=%.0f w=%.0f h=%.0f)", rect.origin.x, rect.origin.y, rect.width,
      rect.height)
  }
}

public enum WindowList {
  /// On-screen windows, front to back, as reported by the window server.
  /// Docs: https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
  public static func onScreen(includeDesktop: Bool = false) -> [CGWin] {
    var options: CGWindowListOption = [.optionOnScreenOnly]
    if !includeDesktop { options.insert(.excludeDesktopElements) }
    return copy(options, relativeTo: kCGNullWindowID)
  }

  /// Windows above `window` (exclusive), front to back.
  public static func above(_ window: CGWindowID) -> [CGWin] {
    copy([.optionOnScreenAboveWindow], relativeTo: window)
  }

  public static func copy(_ options: CGWindowListOption, relativeTo window: CGWindowID) -> [CGWin] {
    guard let raw = CGWindowListCopyWindowInfo(options, window) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap(parse)
  }

  static func parse(_ info: [String: Any]) -> CGWin? {
    guard let id = info[kCGWindowNumber as String] as? CGWindowID,
      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDict)
    else { return nil }
    let name = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return CGWin(
      id: id, pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "?",
      name: name, layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
      alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
      isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
      sharingState: info[kCGWindowSharingState as String] as? Int ?? -1,
      bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
  }

  /// Ordered positions of `ids` inside a front-to-back list (nil = absent).
  public static func zIndex(of id: CGWindowID, in list: [CGWin]) -> Int? {
    list.firstIndex { $0.id == id }
  }
}
