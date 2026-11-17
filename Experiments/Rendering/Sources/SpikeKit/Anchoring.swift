import CoreGraphics

/// Where Variant C puts its effect panel relative to the focused window.
///
/// The focus *group* is the focused window plus the contiguous run of windows
/// of the same pid directly in front of it (sheets, dialogs, utility windows)
/// but not windows behind it inferred solely from rectangle containment.
/// The panel is ordered
/// below the group's rearmost window, so the whole group stays sharp.
///
/// If a foreign window is in front of the group, ordering below the group
/// would leave that window sharp: the plan then has no anchor and the caller
/// falls back to overlay placement (Variant A semantics, every window occludes).
public struct AnchorPlan: Equatable, Sendable {
  public let focused: CGWin
  /// Normal-level group windows, front to back.
  public let group: [CGWin]
  /// Rearmost group window to order below; nil means overlay fallback.
  public let anchor: CGWin?
  /// Normal-level windows behind the group (effect candidates when anchored).
  public let behind: [CGWin]
  /// All normal-level windows considered, front to back.
  public let normal: [CGWin]
  public let surfaces: [CGWin]
  public let reason: String

  public var groupIDs: Set<CGWindowID> { Set(group.map(\.id)) }
}

public enum Anchoring {
  /// Closing windows linger with falling `kCGWindowAlpha`; ignore them.
  public static let minimumAlpha = 0.05

  /// `windows`: foreign windows front to back (own windows already removed).
  public static func plan(
    frontToBack windows: [CGWin], focused: CGWin, parentTolerance: CGFloat = 2
  )
    -> AnchorPlan
  {
    // Desktop widgets belong to the full wallpaper effect, not sharp system
    // holes. Native panels already sit above these negative-level surfaces.
    let surfaces = windows.filter { $0.isMaskEligible && !$0.isDesktopWidget }
    let normal = surfaces.filter(\.isNormalLevel)
    guard let index = normal.firstIndex(where: { $0.id == focused.id }) else {
      return AnchorPlan(
        focused: focused, group: [], anchor: nil, behind: [], normal: normal, surfaces: surfaces,
        reason: "focused window #\(focused.id) is not on screen")
    }
    var start = index
    while start > 0, normal[start - 1].pid == focused.pid { start -= 1 }
    // Containment does not establish a sheet/parent relationship: a smaller
    // document can sit over an unrelated larger window of the same app.
    let end = index
    let group = Array(normal[start...end])
    guard start == 0 else {
      let blocker = normal[start - 1]
      return AnchorPlan(
        focused: focused, group: group, anchor: nil, behind: [], normal: normal, surfaces: surfaces,
        reason: "foreign #\(blocker.id) \(blocker.owner) is in front of the focus group")
    }
    return AnchorPlan(
      focused: focused, group: group, anchor: normal[end], behind: Array(normal[(end + 1)...]),
      normal: normal, surfaces: surfaces,
      reason: group.count == 1 ? "focused window is frontmost" : "group of \(group.count) windows")
  }

  /// Preserve the protected group when relative ordering fails.
  public static func fallback(_ plan: AnchorPlan, reason: String) -> AnchorPlan {
    AnchorPlan(
      focused: plan.focused, group: plan.group, anchor: nil, behind: [],
      normal: plan.normal, surfaces: plan.surfaces, reason: reason)
  }

  /// Ground truth check against a CGWindowList snapshot that includes the own
  /// panels. Anchored: every group window is above every own panel and no other
  /// normal-level window is above any own panel. Overlay: own panels sit above
  /// the normal level.
  public static func isPlacementCorrect(
    frontToBack all: [CGWin], ownIDs: Set<CGWindowID>, plan: AnchorPlan
  ) -> Bool {
    let ownIndices = all.indices.filter { ownIDs.contains(all[$0].id) }
    guard ownIndices.count == ownIDs.count, let lowestOwn = ownIndices.max(),
      let foremostOwn = ownIndices.min()
    else { return false }
    guard plan.anchor != nil else {
      return ownIndices.allSatisfy { all[$0].layer > CGWin.normalLayer }
    }
    let groupIDs = plan.groupIDs
    let above = all[..<lowestOwn].filter {
      !ownIDs.contains($0.id) && $0.isNormalLevel && $0.alpha > minimumAlpha
    }
    let groupAbove = Set(all[..<foremostOwn].filter { $0.isMaskEligible }.map(\.id)).intersection(
      groupIDs)
    return ownIndices.allSatisfy { all[$0].isNormalLevel } && groupAbove == groupIDs
      && above.allSatisfy { groupIDs.contains($0.id) }
  }

  /// Mask pieces for the plan: anchored → only windows behind the group
  /// (the group does not occlude, it is above the panel); overlay → all
  /// normal windows with the group punched out.
  public static func pieces(for plan: AnchorPlan, exceptions: Set<CGWindowID>) -> [MaskPiece] {
    let windows = plan.surfaces.filter {
      // Higher system surfaces already composite above both panel levels.
      // Same-level (1) surfaces still need protection in overlay fallback.
      $0.layer <= CGWin.normalLayer + 1 && (plan.anchor == nil || !plan.groupIDs.contains($0.id))
    }
    let sharp = plan.anchor == nil ? plan.groupIDs.union(exceptions) : exceptions
    return windows.reversed().map {
      MaskPiece(
        rect: $0.bounds, kind: (!($0.isNormalLevel) || sharp.contains($0.id)) ? .punch : .effect)
    }
  }

  /// Holes for the continuous scope surface (`VariantC --mask full`): the
  /// whole scope, desktop included, carries the effect; only the visible parts
  /// of sharp windows are punched out (exceptions behind the panel, plus the
  /// focus group in overlay fallback). Back to front, without the base scope
  /// piece; effect pieces behind the rearmost sharp window are dropped because
  /// the scope already covers them. Empty = no mask needed.
  public static func scopeHoles(
    for plan: AnchorPlan, exceptions: Set<CGWindowID>, clipTo screen: CGRect? = nil
  ) -> [MaskPiece] {
    // A full scope covers wallpaper and every inactive surface. Window level
    // alone is NOT a reason to punch holes: desktop/helper windows can have
    // huge, partially transparent frames. Higher system windows composite
    // above our panel naturally. Only explicitly protected normal windows
    // generate holes; inactive normal windows still occlude those exceptions.
    let windows = plan.normal.filter { plan.anchor == nil || !plan.groupIDs.contains($0.id) }
    let sharp = plan.anchor == nil ? plan.groupIDs.union(exceptions) : exceptions
    let pieces = windows.reversed().map {
      MaskPiece(rect: $0.bounds, kind: sharp.contains($0.id) ? .punch : .effect)
    }
    let backToFront = pieces.compactMap { piece -> MaskPiece? in
      guard let screen else { return piece }
      let rect = piece.rect.intersection(screen)
      guard !rect.isNull && !rect.isEmpty else { return nil }
      return MaskPiece(rect: rect, kind: piece.kind)
    }
    guard let first = backToFront.firstIndex(where: { $0.kind == .punch }) else { return [] }
    return Array(backToFront[first...])
  }

  /// Exact visible rectangles of effect windows for the plan (tiles).
  public static func effectRects(for plan: AnchorPlan, exceptions: Set<CGWindowID>) -> [CGRect] {
    let windows = plan.surfaces.filter { plan.anchor == nil || !plan.groupIDs.contains($0.id) }
    let sharp = plan.anchor == nil ? plan.groupIDs.union(exceptions) : exceptions
    let effectIDs = Set(windows.filter(\.isNormalLevel).map(\.id)).subtracting(sharp)
    return MaskBuilder.visibleEffectRects(frontToBack: windows, effectIDs: effectIDs).flatMap(\.1)
  }

  /// Changes whenever the mask for the plan would change.
  public static func maskSignature(for plan: AnchorPlan) -> String {
    let windows = plan.surfaces.filter { plan.anchor == nil || !plan.groupIDs.contains($0.id) }
    return "anchor=\(plan.anchor?.id ?? 0) group=\(plan.group.map(\.id)) "
      + windows.map { "\($0.id)@\($0.bounds)" }.joined(separator: ";")
  }
}

/// A failed relative order is retried only after its anchor changes or a Space reset.
public struct AnchorFailureCache {
  private var failed: CGWindowID?
  public init() {}
  public mutating func applying(to plan: AnchorPlan) -> AnchorPlan {
    if plan.anchor?.id != failed { failed = nil }
    return failed == nil
      ? plan : Anchoring.fallback(plan, reason: "relative ordering previously failed")
  }
  public mutating func record(_ plan: AnchorPlan) { failed = plan.anchor?.id }
  public mutating func reset() { failed = nil }
}

public enum FocusContinuity {
  public static func target(resolved: CGWin?, previous: CGWin?, ownUIIsActive: Bool) -> CGWin? {
    resolved ?? (ownUIIsActive ? previous : nil)
  }
}

/// Full-scope renderer geometry, distinct from logical focus-switch geometry.
/// The verified group is protected by WindowServer, never by a persistent hole.
public enum FullFocusMask {
  public static func path(
    for plan: AnchorPlan, exceptions: Set<CGWindowID>, screen: CGRect,
    cornerRadius: CGFloat, guardPlacement: Bool = false
  ) -> CGPath {
    let effective = guardPlacement ? Anchoring.fallback(plan, reason: "reorder guard") : plan
    let bounds = CGRect(origin: .zero, size: screen.size)
    var path = CGPath(rect: bounds, transform: nil)
    // Keep global window bounds until after rounding. Rectangular refill
    // occluders must not manufacture rounded gaps in protected exceptions.
    for piece in Anchoring.scopeHoles(for: effective, exceptions: exceptions) {
      let local = MaskPath.local(piece.rect, screen: screen, flipped: false)
      let shape =
        piece.kind == .punch
        ? MaskPath.roundedRect(local, cornerRadius) : CGPath(rect: local, transform: nil)
      path = piece.kind == .punch ? path.subtracting(shape) : path.union(shape)
    }
    return path.intersection(CGPath(rect: bounds, transform: nil))
  }

  /// Only a true focus identity switch retires the outgoing visible focus.
  /// Same-window motion has no transition geometry and cannot leave a trail.
  public static func outgoing(
    from previous: AnchorPlan?, to next: AnchorPlan, exceptions: Set<CGWindowID>,
    screen: CGRect, cornerRadius: CGFloat
  ) -> CGPath? {
    guard let previous, previous.focused.id != next.focused.id else { return nil }
    let old = path(
      for: previous, exceptions: exceptions, screen: screen,
      cornerRadius: cornerRadius, guardPlacement: true)
    let new = path(
      for: next, exceptions: exceptions, screen: screen,
      cornerRadius: cornerRadius, guardPlacement: true)
    return new.subtracting(old)
  }

  /// Mask installed before a reorder. It protects the new focus group in case
  /// the order fails, and keeps the outgoing focus sharp: ordering the panel
  /// above it with a filled mask would flash it blurred before its fade starts.
  public static func reorderGuard(
    from previous: AnchorPlan?, to next: AnchorPlan, exceptions: Set<CGWindowID>,
    screen: CGRect, cornerRadius: CGFloat
  ) -> CGPath {
    let guarded = path(
      for: next, exceptions: exceptions, screen: screen, cornerRadius: cornerRadius,
      guardPlacement: true)
    guard
      let outgoing = outgoing(
        from: previous, to: next, exceptions: exceptions, screen: screen,
        cornerRadius: cornerRadius)
    else { return guarded }
    return guarded.subtracting(outgoing)
  }
}
