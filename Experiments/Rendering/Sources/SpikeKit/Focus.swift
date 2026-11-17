import AppKit
import ApplicationServices

/// Mirrors `Contracts.FocusConfidence` without depending on the root package.
public enum Confidence: String, Sendable {
  case confirmed
  case uncertain
  case unavailable
}

public struct AXWindowInfo: Sendable {
  public let pid: pid_t
  public let frame: CGRect?
  public let title: String?
  public let role: String?
  public let subrole: String?
  public let isMinimized: Bool?
  public let isFullScreen: Bool?
}

public struct FocusResult: Sendable {
  public let window: CGWin?
  public let confidence: Confidence
  public let method: String
  public let detail: String
  public let axWindow: AXWindowInfo?
  public let candidates: Int
}

/// Public-API-only focus resolution.
///
/// AX gives the focused window element but no CGWindowID: the only direct
/// bridge, `_AXUIElementGetWindow`, is private and deliberately not used.
/// Instead the AX frame is matched against CGWindowList entries of the same
/// pid; title and z-order break ties.
@MainActor
public enum FocusResolver {
  /// Never prompts. `AXIsProcessTrustedWithOptions` with the prompt option
  /// would show the system dialog; spikes only report the status.
  /// Docs: https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
  public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  public static func resolve(windows: [CGWin], ownPID: pid_t = getpid(), tolerance: CGFloat = 2)
    -> FocusResult
  {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      return FocusResult(
        window: nil, confidence: .unavailable, method: "none", detail: "no frontmost app",
        axWindow: nil, candidates: 0)
    }
    let pid = app.processIdentifier
    let appWindows = windows.filter { $0.pid == pid && $0.isNormalLevel }

    if pid == ownPID {
      return FocusResult(
        window: nil, confidence: .unavailable, method: "none",
        detail: "own process is frontmost; caller must keep the previous target",
        axWindow: nil, candidates: 0)
    }

    switch focusedAXWindow(pid: pid) {
    case .success(let ax):
      guard let frame = ax.frame else {
        return FocusResult(
          window: nil, confidence: .unavailable, method: "ax", detail: "AX window without frame",
          axWindow: ax, candidates: 0)
      }
      let matches = appWindows.filter { approximatelyEqual($0.bounds, frame, tolerance) }
      if matches.count == 1 {
        return FocusResult(
          window: matches[0], confidence: .confirmed, method: "ax+frame",
          detail: "unique pid+frame match", axWindow: ax, candidates: 1)
      }
      if matches.count > 1, let title = ax.title {
        let titled = matches.filter { $0.name == title }
        if titled.count == 1 {
          return FocusResult(
            window: titled[0], confidence: .confirmed, method: "ax+frame+title",
            detail: "\(matches.count) frame matches, unique title", axWindow: ax,
            candidates: matches.count)
        }
      }
      if let front = matches.first {
        return FocusResult(
          window: front, confidence: .uncertain, method: "ax+frame+zorder",
          detail: "\(matches.count) frame matches, picked frontmost", axWindow: ax,
          candidates: matches.count)
      }
      return FocusResult(
        window: nil, confidence: .unavailable, method: "ax+frame",
        detail: "no CG window with pid \(pid) and frame \(CGWin.format(frame))", axWindow: ax,
        candidates: 0)
    case .failure(let error):
      // Fallback without Accessibility: frontmost normal-level window of the
      // frontmost app. Wrong for e.g. focused windows behind same-app panels.
      let front = appWindows.first
      return FocusResult(
        window: front, confidence: front == nil ? .unavailable : .uncertain,
        method: "frontmost-app-heuristic", detail: "AX unavailable: \(error.description)",
        axWindow: nil, candidates: appWindows.count)
    }
  }

  public struct AXFailure: Error, Sendable {
    public let code: AXError
    public let step: String
    public var description: String { "\(step) failed with AXError \(code.rawValue)" }
  }

  public static func focusedAXWindow(pid: pid_t) -> Result<AXWindowInfo, AXFailure> {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      app, kAXFocusedWindowAttribute as CFString, &value)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return .failure(AXFailure(code: error, step: "AXFocusedWindow"))
    }
    let window = value as! AXUIElement
    return .success(info(for: window, pid: pid))
  }

  public static func info(for window: AXUIElement, pid: pid_t) -> AXWindowInfo {
    var frame: CGRect?
    if let position = axValue(window, kAXPositionAttribute, type: .cgPoint, CGPoint.zero),
      let size = axValue(window, kAXSizeAttribute, type: .cgSize, CGSize.zero)
    {
      // AX positions are global top-left coordinates, the same space as CGWindowList.
      frame = CGRect(origin: position, size: size)
    }
    return AXWindowInfo(
      pid: pid, frame: frame, title: attribute(window, kAXTitleAttribute) as? String,
      role: attribute(window, kAXRoleAttribute) as? String,
      subrole: attribute(window, kAXSubroleAttribute) as? String,
      isMinimized: attribute(window, kAXMinimizedAttribute) as? Bool,
      isFullScreen: attribute(window, "AXFullScreen") as? Bool)
  }

  static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
      ? value : nil
  }

  static func axValue<T: BitwiseCopyable>(
    _ element: AXUIElement, _ name: String, type: AXValueType, _ initial: T
  )
    -> T?
  {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
      return nil
    }
    var result = initial
    return AXValueGetValue(raw as! AXValue, type, &result) ? result : nil
  }

  static func approximatelyEqual(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
      && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
  }
}

/// Keeps the previous target while the spike itself is frontmost (plan 3.1:
/// Sonorus must never declare itself the work target).
@MainActor
public final class FocusTracker {
  public private(set) var last: FocusResult?

  public init() {}

  public func resolve(windows: [CGWin]) -> FocusResult {
    let result = FocusResolver.resolve(windows: windows)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      let last, let kept = last.window, windows.contains(where: { $0.id == kept.id })
    {
      return FocusResult(
        window: kept, confidence: .uncertain, method: "kept-previous",
        detail: "own process frontmost", axWindow: last.axWindow, candidates: last.candidates)
    }
    if result.window != nil { last = result }
    return result
  }
}
