import Contracts
import CoreGraphics

@testable import Rendering

/// Simulated WindowServer: one front-to-back list shared by foreign windows
/// and fake surfaces, so ordering and verification behave like the real list.
@MainActor
final class FakeWindowServer: WindowListReading {
  let ownProcessID: Int32 = 99
  var primaryDisplayHeight: Double? = 900
  var windows: [LiveWindow] = []
  /// Simulates a failed relative order: surfaces end up at the front.
  var ignoresRelativeOrdering = false
  private(set) var reads = 0

  func frontToBackWindows() -> [LiveWindow] {
    reads += 1
    return windows
  }

  func foreign(_ id: UInt32, pid: Int32 = 1, frame: ScreenRect) -> LiveWindow {
    LiveWindow(id: id, ownerPID: pid, frame: frame)
  }

  func remove(_ id: UInt32) { windows.removeAll { $0.id == id } }

  func raise(_ id: UInt32) {
    guard let window = windows.first(where: { $0.id == id }) else { return }
    remove(id)
    let firstNormal = windows.firstIndex { $0.level == 0 } ?? windows.endIndex
    windows.insert(window, at: firstNormal)
  }

  func place(surface id: UInt32, below anchor: UInt32) {
    remove(id)
    let surface = LiveWindow(id: id, ownerPID: ownProcessID, frame: .zero)
    if !ignoresRelativeOrdering, let index = windows.firstIndex(where: { $0.id == anchor }) {
      windows.insert(surface, at: index + 1)
    } else {
      windows.insert(surface, at: windows.firstIndex { $0.level == 0 } ?? windows.endIndex)
    }
  }

  func placeAboveNormal(surface id: UInt32) {
    remove(id)
    windows.insert(LiveWindow(id: id, ownerPID: ownProcessID, level: 1, frame: .zero), at: 0)
  }
}

extension ScreenRect {
  static let zero = ScreenRect(x: 0, y: 0, width: 0, height: 0)
}

@MainActor
final class FakeSurface: EffectSurface {
  let windowID: UInt32
  unowned let server: FakeWindowServer
  var frame: CGRect
  var scale: Double
  var position: SurfacePosition?
  var mask = SurfaceMask.empty
  var values = SurfaceValues.zero
  var animations: [SurfaceAnimation] = []
  var maskChanges = 0
  var orderCalls = 0
  var isClosed = false

  init(windowID: UInt32, server: FakeWindowServer, frame: CGRect, scale: Double) {
    self.windowID = windowID
    self.server = server
    self.frame = frame
    self.scale = scale
  }

  var isVisible: Bool { position != nil }
  var lastAnimation: SurfaceAnimation? { animations.last }

  func setFrame(_ frame: CGRect, scale: Double) {
    self.frame = frame
    self.scale = scale
  }

  func order(below windowID: UInt32) {
    position = .anchored(below: windowID)
    orderCalls += 1
    server.place(surface: self.windowID, below: windowID)
  }

  func orderAboveNormalWindows() {
    position = .overlay
    orderCalls += 1
    server.placeAboveNormal(surface: windowID)
  }

  func hide() {
    position = nil
    server.remove(windowID)
  }

  func setMask(_ mask: SurfaceMask) {
    self.mask = mask
    maskChanges += 1
  }

  func setValues(_ values: SurfaceValues) { self.values = values }

  func animate(_ animation: SurfaceAnimation) {
    animations.append(animation)
    values = animation.final
  }

  func close() {
    hide()
    isClosed = true
  }
}

@MainActor
final class FakeSurfaceFactory: EffectSurfaceMaking {
  let server: FakeWindowServer
  var usesFallbackBlur = false
  var remainingSurfaces = Int.max
  private(set) var surfaces: [FakeSurface] = []
  private(set) var transactions = 0

  init(server: FakeWindowServer) { self.server = server }

  func makeSurface(frame: CGRect, scale: Double) -> (any EffectSurface)? {
    guard remainingSurfaces > 0 else { return nil }
    remainingSurfaces -= 1
    let surface = FakeSurface(
      windowID: UInt32(1000 + surfaces.count), server: server, frame: frame, scale: scale)
    surfaces.append(surface)
    return surface
  }

  func performAtomically(_ changes: () -> Void) {
    transactions += 1
    changes()
  }
}

@MainActor
final class FakeScheduler: TransitionScheduling {
  private final class Entry: ScheduledAction {
    let due: Double
    let action: @MainActor @Sendable () -> Void
    var isCancelled = false

    init(due: Double, action: @escaping @MainActor @Sendable () -> Void) {
      self.due = due
      self.action = action
    }

    func cancel() { isCancelled = true }
  }

  private(set) var now = 0.0
  private var entries: [Entry] = []

  var pendingCount: Int { entries.filter { !$0.isCancelled }.count }

  func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    -> any ScheduledAction
  {
    let entry = Entry(due: now + delay, action: action)
    entries.append(entry)
    return entry
  }

  func advance(by seconds: Double) {
    now += seconds
    while let next = entries.filter({ !$0.isCancelled && $0.due <= now }).min(by: {
      $0.due < $1.due
    }) {
      next.isCancelled = true
      next.action()
    }
    entries.removeAll { $0.isCancelled }
  }
}

@MainActor
final class FakeAccessibility: AccessibilityDisplayOptions {
  var reduceMotion = false
}
