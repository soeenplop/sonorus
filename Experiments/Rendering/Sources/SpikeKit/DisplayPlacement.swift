import CoreGraphics

/// Pure per-display policy. Never order a remote display relative to a foreign
/// window that does not intersect it. Own panels are excluded from every check.
public enum DisplayPlacement {
  public static func plan(_ global: AnchorPlan, screen: CGRect) -> AnchorPlan {
    guard let anchor = global.anchor, anchor.bounds.intersects(screen),
      global.group.contains(where: { $0.bounds.intersects(screen) })
    else { return Anchoring.fallback(global, reason: "no local anchor on display") }
    return global
  }

  public static func verify(
    frontToBack all: [CGWin], panelID: CGWindowID, ownIDs: Set<CGWindowID>,
    expected: CGRect, displayID: CGDirectDisplayID, actualDisplayID: CGDirectDisplayID?,
    plan: AnchorPlan, tolerance: CGFloat = 0.5
  ) -> Bool {
    guard actualDisplayID == displayID,
      let index = all.firstIndex(where: { $0.id == panelID }), all[index].isOnScreen,
      all[index].alpha > Anchoring.minimumAlpha
    else { return false }
    let panel = all[index]
    guard abs(panel.bounds.minX - expected.minX) <= tolerance,
      abs(panel.bounds.minY - expected.minY) <= tolerance,
      abs(panel.bounds.width - expected.width) <= tolerance,
      abs(panel.bounds.height - expected.height) <= tolerance
    else { return false }
    let relevant = all.filter {
      !ownIDs.contains($0.id) && $0.isMaskEligible && $0.bounds.intersects(expected)
    }
    guard plan.anchor != nil else {
      return panel.layer > CGWin.normalLayer
        && relevant.filter(\.isNormalLevel).allSatisfy { window in
          (all.firstIndex { $0.id == window.id } ?? -1) > index
        }
    }
    let group = plan.group.filter { $0.bounds.intersects(expected) }
    return panel.isNormalLevel && !group.isEmpty
      && group.allSatisfy { window in
        guard let position = all.firstIndex(where: { $0.id == window.id }) else { return false }
        return position < index
      }
      && all[..<index].allSatisfy {
        ownIDs.contains($0.id) || !$0.isMaskEligible || !$0.isNormalLevel
          || !$0.bounds.intersects(expected) || plan.groupIDs.contains($0.id)
      }
  }
}

/// Alpha envelope in points, not a variable native blur radius. Only the top
/// menu boundary fades; an auto-hidden menu (inset zero) has no artificial band.
public struct MenuFade: Equatable, Sendable {
  public let height: CGFloat
  public let bounds: CGRect
  public let topInset: CGFloat
  public let flipped: Bool
  public init(
    bounds: CGRect, menuInset: CGFloat, points: CGFloat, topInset: CGFloat = 0,
    flipped: Bool = false
  ) {
    self.bounds = bounds
    self.topInset = max(0, min(topInset, bounds.height))
    self.flipped = flipped
    height =
      menuInset > 0 && points.isFinite
      ? max(0, min(points, max(0, bounds.height - self.topInset))) : 0
  }
  /// Finish the transition inside the menu strip, not over document chrome.
  /// Fading below the bar reveals bright, unblurred title bars as a white band.
  public static func insideMenuBar(bounds: CGRect, menuInset: CGFloat, points: CGFloat) -> MenuFade
  {
    let inset = menuInset.isFinite ? max(0, min(menuInset, bounds.height)) : 0
    let length = points.isFinite ? max(0, min(points, inset)) : 0
    return MenuFade(bounds: bounds, menuInset: inset, points: length, topInset: inset - length)
  }

  public func opacity(distanceBelowTop distance: CGFloat) -> CGFloat {
    height == 0 ? 1 : max(0, min(1, distance / height))
  }
  private func unitY(_ distance: CGFloat) -> CGFloat {
    let value = bounds.height > 0 ? distance / bounds.height : 0
    return flipped ? value : 1 - value
  }
  public var startPoint: CGPoint { CGPoint(x: 0.5, y: unitY(topInset)) }
  public var endPoint: CGPoint { CGPoint(x: 0.5, y: unitY(topInset + height)) }
}
