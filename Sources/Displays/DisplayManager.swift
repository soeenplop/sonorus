import AppKit
import Contracts

/// `DisplayProviding` backed by a `DisplaySource`.
///
/// While started, the display list is cached and refreshed on
/// `NSApplication.didChangeScreenParametersNotification`; `changes()` yields
/// only when the set, identity, frames, names or scales actually changed (the
/// notification also fires for unrelated parameter changes). While stopped,
/// `currentDisplays()` reads the source on every call.
@MainActor
public final class DisplayManager: DisplayProviding {
  private let source: any DisplaySource
  private let notificationCenter: NotificationCenter
  private var observer: (any NSObjectProtocol)?
  private var cached: [DisplaySnapshot]?
  private var continuations: [UUID: AsyncStream<[DisplaySnapshot]>.Continuation] = [:]

  public init(
    source: any DisplaySource = ScreenDisplaySource(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.source = source
    self.notificationCenter = notificationCenter
  }

  public var isStarted: Bool { observer != nil }

  public func start() {
    guard observer == nil else { return }
    cached = read()
    observer = notificationCenter.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.refresh() }
    }
  }

  public func stop() {
    if let observer { notificationCenter.removeObserver(observer) }
    observer = nil
    cached = nil
    for continuation in continuations.values { continuation.finish() }
    continuations.removeAll()
  }

  public func currentDisplays() -> [DisplaySnapshot] {
    cached ?? read()
  }

  /// New display lists after real changes; the current list is not replayed.
  public func changes() -> AsyncStream<[DisplaySnapshot]> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<[DisplaySnapshot]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  /// Re-reads the source; returns whether the list changed.
  @discardableResult
  func refresh() -> Bool {
    guard isStarted else { return false }
    let displays = read()
    guard displays != cached else { return false }
    cached = displays
    for continuation in continuations.values { continuation.yield(displays) }
    return true
  }

  private func read() -> [DisplaySnapshot] {
    DisplayIdentity.snapshots(for: source.displays())
  }
}
