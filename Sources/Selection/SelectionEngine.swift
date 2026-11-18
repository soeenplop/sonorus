import Contracts
import Foundation

/// Eight resize handles of a region. Corners come first so they win ties over edges.
enum RegionHandle: CaseIterable, Equatable, Sendable {
  case topLeft, topRight, bottomRight, bottomLeft
  case top, right, bottom, left

  var movesLeftEdge: Bool { self == .topLeft || self == .bottomLeft || self == .left }
  var movesRightEdge: Bool { self == .topRight || self == .bottomRight || self == .right }
  var movesTopEdge: Bool { self == .topLeft || self == .topRight || self == .top }
  var movesBottomEdge: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }

  /// Position of the handle on `rect` (Quartz coordinates, y down).
  func position(on rect: ScreenRect) -> ScreenPoint {
    let midX = rect.x + rect.width / 2
    let midY = rect.y + rect.height / 2
    switch self {
    case .topLeft: return ScreenPoint(x: rect.minX, y: rect.minY)
    case .top: return ScreenPoint(x: midX, y: rect.minY)
    case .topRight: return ScreenPoint(x: rect.maxX, y: rect.minY)
    case .right: return ScreenPoint(x: rect.maxX, y: midY)
    case .bottomRight: return ScreenPoint(x: rect.maxX, y: rect.maxY)
    case .bottom: return ScreenPoint(x: midX, y: rect.maxY)
    case .bottomLeft: return ScreenPoint(x: rect.minX, y: rect.maxY)
    case .left: return ScreenPoint(x: rect.minX, y: midY)
    }
  }
}

enum SelectionCursor: Equatable, Sendable {
  case crosshair
  case move
  case resize(RegionHandle)
}

/// Pure state machine of one selection pass. It works on a detached copy of the
/// draft and never touches AppKit; the presenter only forwards pointer and key
/// events and renders `scene`. All coordinates are global Quartz points.
///
/// Rules worth knowing:
/// - Window hit-testing walks the snapshot front to back and skips system UI,
///   off-screen windows and windows of excluded owners (Sonorus itself).
/// - A region always belongs to the display where its drag started; the gesture
///   is clamped to that display. Regions of displays missing from the snapshot
///   are kept untouched but are neither shown nor editable.
/// - Displays whose persistent `DisplayID` occurs more than once in the snapshot
///   (identical monitors) are ambiguous: they cannot be selected, regions cannot
///   be drawn on them, and anything saved for that ID is kept but not shown.
/// - Esc discards everything, even mid-gesture.
struct SelectionEngine: Sendable {
  static let minimumRegionSize = 16.0
  static let handleHitRadius = 8.0
  static let dragThreshold = 3.0

  let desktop: DesktopSnapshot
  let initialDraft: SelectionDraft
  let excludedOwnerPIDs: Set<Int32>
  /// IDs shared by several displays of the snapshot; those displays are not selectable.
  let ambiguousDisplayIDs: Set<DisplayID>

  private(set) var mode: SelectionMode
  private(set) var draft: SelectionDraft
  private(set) var outcome: SelectionOutcome?
  private(set) var hoveredWindow: WindowReference?
  private(set) var hoveredDisplay: DisplayID?
  private(set) var selectedRegionID: UUID?
  private(set) var pointer: ScreenPoint?
  private var gesture: Gesture?

  private enum Target: Equatable {
    case window(WindowReference)
    case display(DisplayID)
  }

  private enum Gesture {
    case pressing(Target)
    case creating(displayID: DisplayID, frame: ScreenRect, start: ScreenPoint, current: ScreenPoint)
    case moving(
      id: UUID, display: ScreenRect, origin: ScreenRect, start: ScreenPoint,
      cycleOnClick: Bool, moved: Bool)
    case resizing(
      id: UUID, handle: RegionHandle, display: ScreenRect, origin: ScreenRect, start: ScreenPoint)
  }

  init(request: SelectionRequest, excludedOwnerPIDs: Set<Int32> = []) {
    desktop = request.desktop
    initialDraft = request.draft
    draft = request.draft
    mode = request.mode
    self.excludedOwnerPIDs = excludedOwnerPIDs
    ambiguousDisplayIDs = Self.ambiguousIDs(in: request.desktop.displays)
  }

  static func ambiguousIDs(in displays: [DisplaySnapshot]) -> Set<DisplayID> {
    var seen = Set<DisplayID>()
    var ambiguous = Set<DisplayID>()
    for display in displays where !seen.insert(display.id).inserted {
      ambiguous.insert(display.id)
    }
    return ambiguous
  }

  var isFinished: Bool { outcome != nil }

  // MARK: Hit-testing

  /// Front-most selectable window containing `point`.
  func window(at point: ScreenPoint) -> WindowSnapshot? {
    desktop.windows.first { isSelectable($0) && $0.frame.contains(point) }
  }

  func display(at point: ScreenPoint) -> DisplaySnapshot? {
    desktop.displays.first { $0.frame.containsHalfOpen(point) }
  }

  /// Like `display(at:)`, but `nil` for ambiguous displays.
  private func selectableDisplay(at point: ScreenPoint) -> DisplaySnapshot? {
    display(at: point).flatMap { ambiguousDisplayIDs.contains($0.id) ? nil : $0 }
  }

  private func isSelectable(_ window: WindowSnapshot) -> Bool {
    window.isOnScreen && !window.isSystemUI && window.frame.isUsable
      && !excludedOwnerPIDs.contains(window.reference.ownerPID)
  }

  /// Frame of the display `id` refers to; `nil` if it is missing or ambiguous.
  private func displayFrame(_ id: DisplayID) -> ScreenRect? {
    guard !ambiguousDisplayIDs.contains(id) else { return nil }
    return desktop.displays.first { $0.id == id }?.frame
  }

  /// Regions that can be shown and edited, in draw order (last is on top).
  var editableRegions: [(region: FocusRegion, frame: ScreenRect)] {
    draft.regions.compactMap { region in
      displayFrame(region.displayID).map { (region, region.rect.absolute(in: $0)) }
    }
  }

  private func regionFrame(_ id: UUID) -> (region: FocusRegion, frame: ScreenRect)? {
    editableRegions.first { $0.region.id == id }
  }

  func handle(at point: ScreenPoint, of frame: ScreenRect) -> RegionHandle? {
    let radius = min(Self.handleHitRadius, min(frame.width, frame.height) / 3)
    return RegionHandle.allCases
      .map { ($0, $0.position(on: frame).chebyshevDistance(to: point)) }
      .filter { $0.1 <= radius }
      .min { $0.1 < $1.1 }?.0
  }

  /// Regions under `point`, topmost first.
  private func regions(at point: ScreenPoint) -> [UUID] {
    editableRegions.reversed().filter { $0.frame.contains(point) }.map(\.region.id)
  }

  func cursor(at point: ScreenPoint) -> SelectionCursor {
    switch gesture {
    case .moving: return .move
    case .resizing(_, let handle, _, _, _): return .resize(handle)
    case .creating, .pressing: return .crosshair
    case nil: break
    }
    guard mode == .regions else { return .crosshair }
    if let id = selectedRegionID, let selected = regionFrame(id),
      let handle = handle(at: point, of: selected.frame)
    {
      return .resize(handle)
    }
    return regions(at: point).isEmpty ? .crosshair : .move
  }

  // MARK: Mode

  mutating func setMode(_ newMode: SelectionMode) {
    guard outcome == nil, newMode != mode else { return }
    mode = newMode
    gesture = nil
    selectedRegionID = nil
    hoveredWindow = nil
    hoveredDisplay = nil
    if let pointer { updateHover(at: pointer) }
  }

  // MARK: Pointer

  mutating func pointerMoved(to point: ScreenPoint) {
    guard outcome == nil else { return }
    pointer = point
    updateHover(at: point)
  }

  /// The pointer is over the toolbar: nothing below it is hovered.
  mutating func pointerLeft() {
    guard outcome == nil, gesture == nil else { return }
    pointer = nil
    hoveredWindow = nil
    hoveredDisplay = nil
  }

  mutating func pointerDown(at point: ScreenPoint, startsNewRegion: Bool = false) {
    guard outcome == nil else { return }
    pointer = point
    updateHover(at: point)
    gesture = nil
    switch mode {
    case .windows:
      if let window = window(at: point) { gesture = .pressing(.window(window.reference)) }
    case .displays:
      if let display = selectableDisplay(at: point) {
        gesture = .pressing(.display(display.id))
      }
    case .regions:
      regionPointerDown(at: point, startsNewRegion: startsNewRegion)
    }
  }

  mutating func pointerDragged(to point: ScreenPoint) {
    guard outcome == nil else { return }
    pointer = point
    switch gesture {
    case .creating(let id, let frame, let start, _):
      gesture = .creating(displayID: id, frame: frame, start: start, current: frame.clamped(point))
    case .moving(let id, let display, let origin, let start, let cycle, var moved):
      if !moved, point.chebyshevDistance(to: start) < Self.dragThreshold { return }
      moved = true
      gesture = .moving(
        id: id, display: display, origin: origin, start: start, cycleOnClick: cycle, moved: moved)
      moveRegion(id, display: display, origin: origin, dx: point.x - start.x, dy: point.y - start.y)
    case .resizing(let id, let handle, let display, let origin, let start):
      resizeRegion(
        id, handle: handle, display: display, origin: origin,
        dx: point.x - start.x, dy: point.y - start.y)
    case .pressing, nil:
      updateHover(at: point)
    }
  }

  mutating func pointerUp(at point: ScreenPoint) {
    guard outcome == nil else { return }
    pointer = point
    defer { gesture = nil }
    switch gesture {
    case .pressing(let target):
      switch (target, mode) {
      case (.window(let reference), .windows) where window(at: point)?.reference == reference:
        toggle(&draft.windows, reference)
      case (.display(let id), .displays) where selectableDisplay(at: point)?.id == id:
        toggle(&draft.displays, id)
      default: break
      }
    case .creating(let id, let frame, let start, _):
      finishCreation(displayID: id, frame: frame, start: start, end: frame.clamped(point))
    case .moving(let id, _, _, _, let cycle, let moved):
      if cycle, !moved { cycleSelection(at: point, from: id) }
    case .resizing, nil:
      break
    }
    updateHover(at: point)
  }

  /// Press and release at the same point.
  mutating func click(at point: ScreenPoint) {
    pointerDown(at: point)
    pointerUp(at: point)
  }

  // MARK: Regions

  private mutating func regionPointerDown(at point: ScreenPoint, startsNewRegion: Bool) {
    if !startsNewRegion {
      if let id = selectedRegionID, let selected = regionFrame(id),
        let handle = handle(at: point, of: selected.frame),
        let display = displayFrame(selected.region.displayID)
      {
        gesture = .resizing(
          id: id, handle: handle, display: display, origin: selected.frame, start: point)
        return
      }
      // The selected region wins over regions stacked above it, so overlapping
      // regions stay editable: click-without-drag then cycles through the stack.
      var candidates = regions(at: point)
      if let id = selectedRegionID, let index = candidates.firstIndex(of: id) {
        candidates.remove(at: index)
        candidates.insert(id, at: 0)
      }
      if let id = candidates.first, let hit = regionFrame(id),
        let display = displayFrame(hit.region.displayID)
      {
        let cycles = id == selectedRegionID && candidates.count > 1
        selectedRegionID = id
        gesture = .moving(
          id: id, display: display, origin: hit.frame, start: point,
          cycleOnClick: cycles, moved: false)
        return
      }
    }
    selectedRegionID = nil
    if let display = selectableDisplay(at: point) {
      gesture = .creating(
        displayID: display.id, frame: display.frame, start: point, current: point)
    }
  }

  private mutating func finishCreation(
    displayID: DisplayID, frame: ScreenRect, start: ScreenPoint, end: ScreenPoint
  ) {
    let rect = ScreenRect(from: start, to: end)
    guard rect.width >= Self.minimumRegionSize, rect.height >= Self.minimumRegionSize else {
      return
    }
    let region = FocusRegion(displayID: displayID, rect: rect.normalized(in: frame))
    draft.regions.append(region)
    selectedRegionID = region.id
  }

  private mutating func cycleSelection(at point: ScreenPoint, from id: UUID) {
    let stack = regions(at: point)
    guard stack.count > 1, let index = stack.firstIndex(of: id) else { return }
    selectedRegionID = stack[(index + 1) % stack.count]
  }

  private mutating func moveRegion(
    _ id: UUID, display: ScreenRect, origin: ScreenRect, dx: Double, dy: Double
  ) {
    let x = min(max(origin.x + dx, display.minX), display.maxX - origin.width)
    let y = min(max(origin.y + dy, display.minY), display.maxY - origin.height)
    updateRegion(
      id, to: ScreenRect(x: x, y: y, width: origin.width, height: origin.height), in: display)
  }

  private mutating func resizeRegion(
    _ id: UUID, handle: RegionHandle, display: ScreenRect, origin: ScreenRect,
    dx: Double, dy: Double
  ) {
    let minimum = min(Self.minimumRegionSize, display.width, display.height)
    var left = origin.minX
    var right = origin.maxX
    var top = origin.minY
    var bottom = origin.maxY
    if handle.movesLeftEdge { left = min(max(left + dx, display.minX), right - minimum) }
    if handle.movesRightEdge { right = max(min(right + dx, display.maxX), left + minimum) }
    if handle.movesTopEdge { top = min(max(top + dy, display.minY), bottom - minimum) }
    if handle.movesBottomEdge { bottom = max(min(bottom + dy, display.maxY), top + minimum) }
    updateRegion(
      id, to: ScreenRect(minX: left, minY: top, maxX: right, maxY: bottom), in: display)
  }

  private mutating func updateRegion(_ id: UUID, to frame: ScreenRect, in display: ScreenRect) {
    guard let index = draft.regions.firstIndex(where: { $0.id == id }) else { return }
    draft.regions[index].rect = frame.normalized(in: display)
  }

  @discardableResult
  mutating func deleteSelectedRegion() -> Bool {
    guard outcome == nil, mode == .regions, let id = selectedRegionID,
      let index = draft.regions.firstIndex(where: { $0.id == id })
    else { return false }
    draft.regions.remove(at: index)
    selectedRegionID = nil
    gesture = nil
    return true
  }

  @discardableResult
  mutating func toggleSelectedRegionEnabled() -> Bool {
    guard outcome == nil, mode == .regions, let id = selectedRegionID,
      let index = draft.regions.firstIndex(where: { $0.id == id })
    else { return false }
    draft.regions[index].isEnabled.toggle()
    return true
  }

  /// Keyboard access to every region, including ones completely covered by others.
  mutating func selectNextRegion(backward: Bool = false) {
    guard outcome == nil, mode == .regions else { return }
    let ids = editableRegions.map(\.region.id)
    guard !ids.isEmpty else { return }
    guard let current = selectedRegionID.flatMap({ ids.firstIndex(of: $0) }) else {
      selectedRegionID = backward ? ids.last : ids.first
      return
    }
    selectedRegionID = ids[(current + (backward ? ids.count - 1 : 1)) % ids.count]
  }

  // MARK: Finish

  /// Applies the draft. A gesture that is still being drawn is dropped.
  mutating func confirm() {
    guard outcome == nil else { return }
    gesture = nil
    outcome = .confirmed(draft, mode: mode)
  }

  /// Discards every change of this pass and restores the previous draft.
  mutating func cancel() {
    guard outcome == nil else { return }
    gesture = nil
    draft = initialDraft
    outcome = .cancelled
  }

  // MARK: Helpers

  private mutating func updateHover(at point: ScreenPoint) {
    hoveredWindow = nil
    hoveredDisplay = nil
    switch mode {
    case .windows: hoveredWindow = window(at: point)?.reference
    case .displays: hoveredDisplay = selectableDisplay(at: point)?.id
    case .regions: break
    }
  }

  private func toggle<Element: Hashable>(_ set: inout Set<Element>, _ element: Element) {
    if set.remove(element) == nil { set.insert(element) }
  }

  // MARK: Scene

  /// Everything the presenter needs to draw, limited to what the current mode shows.
  var scene: SelectionScene {
    var scene = SelectionScene(mode: mode)
    scene.displays = desktop.displays.map {
      let isAmbiguous = ambiguousDisplayIDs.contains($0.id)
      return SelectionScene.DisplayMark(
        id: $0.id, runtimeID: $0.runtimeID, name: $0.name, frame: $0.frame, scale: $0.scale,
        isAmbiguous: isAmbiguous,
        isHovered: mode == .displays && !isAmbiguous && hoveredDisplay == $0.id,
        isSelected: mode == .displays && !isAmbiguous && draft.displays.contains($0.id))
    }
    switch mode {
    case .windows:
      // Back to front, so the hovered window is drawn last.
      scene.windows = desktop.windows.reversed().compactMap { window in
        let selected = draft.windows.contains(window.reference)
        let hovered = hoveredWindow == window.reference
        guard isSelectable(window), selected || hovered else { return nil }
        return SelectionScene.WindowMark(
          reference: window.reference, frame: window.frame, isHovered: hovered,
          isSelected: selected)
      }
    case .regions:
      scene.regions = editableRegions.map {
        SelectionScene.RegionMark(
          id: $0.region.id, displayID: $0.region.displayID, frame: $0.frame,
          isEnabled: $0.region.isEnabled, isSelected: $0.region.id == selectedRegionID)
      }
      if let id = selectedRegionID, let selected = regionFrame(id) {
        scene.handles = RegionHandle.allCases.map {
          SelectionScene.HandleMark(handle: $0, position: $0.position(on: selected.frame))
        }
      }
      if case .creating(let id, _, let start, let current) = gesture {
        scene.preview = SelectionScene.Preview(
          displayID: id, frame: ScreenRect(from: start, to: current))
      }
    case .displays:
      break
    }
    return scene
  }
}
