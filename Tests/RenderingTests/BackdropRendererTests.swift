import Contracts
import CoreGraphics
import TestSupport
import XCTest

@testable import Rendering

@MainActor
final class BackdropRendererTests: XCTestCase {
  private let windowA = DesktopFixtures.focused
  private let windowB = DesktopFixtures.background
  private let primary = DisplayPlacement(
    runtimeID: 1, displayID: DesktopFixtures.primaryID,
    frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900))
  private let secondary = DisplayPlacement(
    runtimeID: 2, displayID: DesktopFixtures.secondaryID,
    frame: ScreenRect(x: -1920, y: -100, width: 1920, height: 1080))
  private let target = EffectAppearance(EffectSettings()).values

  private var server: FakeWindowServer!
  private var factory: FakeSurfaceFactory!
  private var scheduler: FakeScheduler!
  private var accessibility: FakeAccessibility!
  private var renderer: BackdropRenderer!

  override func setUp() async throws {
    server = FakeWindowServer()
    factory = FakeSurfaceFactory(server: server)
    scheduler = FakeScheduler()
    accessibility = FakeAccessibility()
    renderer = BackdropRenderer(
      factory: factory, windowList: server, scheduler: scheduler, accessibility: accessibility)
    let desktop = DesktopFixtures.overlappingWindows()
    server.windows = desktop.windows.map {
      server.foreign($0.reference.windowID, pid: $0.reference.ownerPID, frame: $0.frame)
    }
  }

  // MARK: Helpers

  private func mask(
    _ placement: DisplayPlacement, anchored: [ScreenRect]? = nil, overlay: [ScreenRect]? = nil
  ) -> DisplayEffectMask {
    let frame = placement.frame
    let strip = ScreenRect(x: frame.x, y: frame.y, width: 50, height: frame.height)
    return DisplayEffectMask(
      placement: placement, anchored: anchored ?? [frame], overlay: overlay ?? [strip])
  }

  private func scene(
    anchor window: WindowReference?, masks: [DisplayEffectMask]? = nil,
    effects: EffectSettings = EffectSettings()
  ) -> RenderScene {
    RenderScene(
      revision: 1, masks: masks ?? [mask(primary), mask(secondary)], effects: effects,
      anchor: window.map { RenderAnchor(window: $0, group: [$0]) })
  }

  private func render(_ scene: RenderScene, desktop: DesktopSnapshot? = nil) async throws {
    try await renderer.render(scene, desktop: desktop ?? DesktopFixtures.overlappingWindows())
  }

  private var primaryActive: FakeSurface { surface(primaryIndex: 0) }
  private var primarySpare: FakeSurface { surface(primaryIndex: 1) }

  private func surface(primaryIndex: Int) -> FakeSurface { factory.surfaces[primaryIndex] }

  private func visible(_ surfaces: [FakeSurface]) -> [FakeSurface] {
    surfaces.filter(\.isVisible)
  }

  private func stripMask(height: Double) -> SurfaceMask {
    .rects([CGRect(x: 0, y: 0, width: 50, height: height)])
  }

  // MARK: Anchored rendering

  func testFirstRenderFadesInDirectlyBelowTheAnchor() async throws {
    try await render(scene(anchor: windowA))

    XCTAssertEqual(factory.surfaces.count, 4)
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(primaryActive.mask, .full)
    XCTAssertFalse(primarySpare.isVisible)
    let fade = try XCTUnwrap(primaryActive.lastAnimation)
    XCTAssertEqual(fade.frames.first, .zero)
    XCTAssertEqual(fade.final, target)
    XCTAssertEqual(fade.duration, 0.75)
    XCTAssertEqual(factory.surfaces[2].position, .anchored(below: 101))
    XCTAssertEqual(server.windows.map(\.id), [101, 1002, 1000, 102])
    XCTAssertEqual(server.reads, 2)

    scheduler.advance(by: 0.75)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(primaryActive.values, target)
  }

  func testSurfacesUseAppKitFramesAndDisplayScale() async throws {
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.frame, CGRect(x: 0, y: 0, width: 1440, height: 900))
    XCTAssertEqual(primaryActive.scale, 2)
    XCTAssertEqual(factory.surfaces[2].frame, CGRect(x: -1920, y: -80, width: 1920, height: 1080))
    XCTAssertEqual(factory.surfaces[2].scale, 1)

    let moved = DisplayPlacement(
      runtimeID: 2, displayID: DesktopFixtures.secondaryID,
      frame: ScreenRect(x: 1440, y: 0, width: 1920, height: 1080))
    try await render(scene(anchor: windowA, masks: [mask(primary), mask(moved)]))
    XCTAssertEqual(factory.surfaces.count, 4)
    for surface in factory.surfaces[2...] {
      XCTAssertEqual(surface.frame, CGRect(x: 1440, y: -180, width: 1920, height: 1080))
    }
  }

  func testVerifiedSurfaceIsNotReordered() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    let calls = primaryActive.orderCalls
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.orderCalls, calls)
    XCTAssertEqual(primaryActive.animations.count, 1)
  }

  func testDriftBehindTheAnchorIsReordered() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    // A foreign window slipped between the anchor and the surface.
    server.windows.insert(
      server.foreign(103, frame: ScreenRect(x: 0, y: 0, width: 300, height: 300)), at: 1)
    let calls = primaryActive.orderCalls
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.orderCalls, calls + 1)
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(server.windows.prefix(2).map(\.id), [101, 1000])
  }

  // MARK: Overlay fallback

  func testForeignWindowAboveTheAnchorUsesTheOverlayMask() async throws {
    server.windows.insert(
      server.foreign(103, pid: 7, frame: ScreenRect(x: 0, y: 0, width: 300, height: 300)), at: 0)
    try await render(scene(anchor: windowA))

    XCTAssertEqual(primaryActive.position, .overlay)
    XCTAssertEqual(primaryActive.mask, stripMask(height: 900))
    // The foreign window does not reach the secondary display.
    XCTAssertEqual(factory.surfaces[2].position, .anchored(below: 101))
    XCTAssertEqual(factory.surfaces[2].mask, .full)
  }

  func testFailedOrderingIsDemotedOnlyAfterTheGracePeriod() async throws {
    server.ignoresRelativeOrdering = true
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.position, .anchored(below: 101), "the list may be a frame late")
    scheduler.advance(by: BackdropRenderer.overlayGrace)
    XCTAssertEqual(primaryActive.position, .overlay)
    XCTAssertEqual(primaryActive.mask, stripMask(height: 900))
    XCTAssertEqual(factory.surfaces[2].position, .overlay)
    XCTAssertEqual(factory.surfaces[2].mask, stripMask(height: 1080))
  }

  func testFailedAnchoringIsRetriedOnlyAfterABackoff() async throws {
    server.ignoresRelativeOrdering = true
    try await render(scene(anchor: windowA))
    scheduler.advance(by: BackdropRenderer.overlayGrace)
    scheduler.advance(by: 0.2)
    let animations = primaryActive.animations.count + primarySpare.animations.count
    server.ignoresRelativeOrdering = false
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.position, .overlay)
    XCTAssertEqual(primaryActive.animations.count + primarySpare.animations.count, animations)
  }

  func testAnchoringResumesAfterTheBackoff() async throws {
    server.ignoresRelativeOrdering = true
    try await render(scene(anchor: windowA))
    scheduler.advance(by: BackdropRenderer.overlayGrace)
    server.ignoresRelativeOrdering = false
    scheduler.advance(by: BackdropRenderer.anchorRetryInterval)
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primarySpare.position, .anchored(below: 101))
    XCTAssertEqual(primarySpare.lastAnimation, .crossIn(to: target, duration: 0.75))
    XCTAssertEqual(primarySpare.mask, .full)
  }

  func testAnchoredDisplayWaitsBeforeFallingBackToOverlay() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    let animations = primaryActive.animations.count + primarySpare.animations.count
    // Right after a switch the list still shows another window in front.
    server.windows.insert(
      server.foreign(103, pid: 7, frame: ScreenRect(x: 0, y: 0, width: 300, height: 300)), at: 0)
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(primaryActive.animations.count + primarySpare.animations.count, animations)
    scheduler.advance(by: BackdropRenderer.overlayGrace)
    XCTAssertEqual(primarySpare.position, .overlay, "a persistent foreign window wins")
    XCTAssertEqual(primarySpare.mask, stripMask(height: 900))
  }

  func testAnchoredDisplayKeepsItsPlacementWhenTheAnchorArrivesInTime() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    server.windows.insert(
      server.foreign(103, pid: 7, frame: ScreenRect(x: 0, y: 0, width: 300, height: 300)), at: 0)
    try await render(scene(anchor: windowA))
    server.remove(103)
    try await render(scene(anchor: windowA))
    scheduler.advance(by: BackdropRenderer.overlayGrace)
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(primaryActive.mask, .full)
  }

  func testMissingAnchorWindowUsesTheOverlayMask() async throws {
    server.remove(101)
    try await render(scene(anchor: windowA))
    XCTAssertEqual(primaryActive.position, .overlay)
  }

  func testWithoutAnchorOnlyOverlayMasksAreUsed() async throws {
    try await render(scene(anchor: nil))
    XCTAssertEqual(primaryActive.position, .overlay)
    XCTAssertEqual(primaryActive.mask, stripMask(height: 900))
    XCTAssertEqual(server.reads, 0)
    XCTAssertEqual(server.windows.first?.level, 1)
  }

  // MARK: Focus switches

  func testFocusSwitchCrossBlursIntoTheSpareSurface() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    server.raise(102)
    try await render(scene(anchor: windowB))

    XCTAssertEqual(primarySpare.position, .anchored(below: 102))
    XCTAssertEqual(primarySpare.lastAnimation, .crossIn(to: target, duration: 0.75))
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(primaryActive.lastAnimation, .crossOut(from: target, duration: 0.75))
    XCTAssertEqual(primarySpare.lastAnimation?.frames.first, .zero)

    scheduler.advance(by: 0.75)
    XCTAssertFalse(primaryActive.isVisible)
    XCTAssertEqual(primaryActive.values, .zero)
    XCTAssertEqual(primarySpare.values, target)
    XCTAssertEqual(primarySpare.position, .anchored(below: 102))
  }

  func testNewSwitchFinishesTheRunningTransitionImmediately() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    server.raise(102)
    try await render(scene(anchor: windowB))
    scheduler.advance(by: 0.2)
    server.raise(101)
    try await render(scene(anchor: windowA))

    // The old outgoing surface left and returns as the incoming one.
    XCTAssertEqual(primaryActive.position, .anchored(below: 101))
    XCTAssertEqual(primaryActive.lastAnimation, .crossIn(to: target, duration: 0.75))
    XCTAssertEqual(primarySpare.lastAnimation, .crossOut(from: target, duration: 0.75))
    XCTAssertEqual(scheduler.pendingCount, 2)

    scheduler.advance(by: 0.75)
    XCTAssertFalse(primarySpare.isVisible)
    XCTAssertEqual(primaryActive.values, target)
    XCTAssertEqual(scheduler.pendingCount, 0)
  }

  func testReduceMotionSwitchesInstantly() async throws {
    accessibility.reduceMotion = true
    try await render(scene(anchor: windowA))
    XCTAssertTrue(primaryActive.animations.isEmpty)
    XCTAssertEqual(primaryActive.values, target)

    server.raise(102)
    try await render(scene(anchor: windowB))
    XCTAssertEqual(primaryActive.position, .anchored(below: 102))
    XCTAssertTrue(primaryActive.animations.isEmpty)
    XCTAssertFalse(primarySpare.isVisible)
    XCTAssertEqual(scheduler.pendingCount, 0)
  }

  func testZeroDurationSwitchesInstantly() async throws {
    let instant = EffectSettings(transitionDuration: 0)
    try await render(scene(anchor: windowA, effects: instant))
    server.raise(102)
    try await render(scene(anchor: windowB, effects: instant))
    XCTAssertEqual(primaryActive.position, .anchored(below: 102))
    XCTAssertTrue(primaryActive.animations.isEmpty)
    XCTAssertFalse(primarySpare.isVisible)
  }

  // MARK: Instant changes

  func testMaskChangeWithoutAnchorChangeIsInstant() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    let half = ScreenRect(x: 0, y: 0, width: 720, height: 900)
    try await render(scene(anchor: windowA, masks: [mask(primary, anchored: [half])]))

    XCTAssertEqual(primaryActive.mask, .rects([CGRect(x: 0, y: 0, width: 720, height: 900)]))
    XCTAssertEqual(primaryActive.animations.count, 1)
    XCTAssertFalse(primarySpare.isVisible)
    XCTAssertEqual(scheduler.pendingCount, 0)
  }

  func testSettingsChangeIsInstant() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    let stronger = EffectSettings(blur: 1, backgroundBrightness: 0.5)
    try await render(scene(anchor: windowA, effects: stronger))
    XCTAssertEqual(primaryActive.values, SurfaceValues(radius: 64, dim: 0.5, blurOpacity: 1))
    XCTAssertEqual(primaryActive.animations.count, 1)
  }

  // MARK: Enable and disable

  func testEmptyMaskFadesOutThenHides() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    let empty = [mask(primary, anchored: [], overlay: [])]
    try await render(scene(anchor: nil, masks: empty))

    XCTAssertTrue(primaryActive.isVisible)
    XCTAssertEqual(primaryActive.lastAnimation?.frames.first, target)
    XCTAssertEqual(primaryActive.lastAnimation?.final, .zero)
    scheduler.advance(by: 0.75)
    XCTAssertFalse(primaryActive.isVisible)
    XCTAssertFalse(primarySpare.isVisible)
  }

  func testEmptyMaskHidesImmediatelyWithReduceMotion() async throws {
    try await render(scene(anchor: windowA))
    accessibility.reduceMotion = true
    try await render(scene(anchor: nil, masks: [mask(primary, anchored: [], overlay: [])]))
    XCTAssertFalse(primaryActive.isVisible)
    XCTAssertEqual(primaryActive.values, .zero)
  }

  func testReturningDuringFadeOutContinuesFromTheCurrentValues() async throws {
    try await render(scene(anchor: windowA))
    scheduler.advance(by: 1)
    try await render(scene(anchor: nil, masks: [mask(primary, anchored: [], overlay: [])]))
    scheduler.advance(by: 0.375)
    try await render(scene(anchor: windowA))

    let resumed = try XCTUnwrap(primaryActive.lastAnimation?.frames.first)
    XCTAssertEqual(resumed.radius, target.radius / 2, accuracy: 1e-9)
    XCTAssertEqual(resumed.dim, target.dim / 2, accuracy: 1e-9)
    XCTAssertTrue(primaryActive.isVisible)
    scheduler.advance(by: 0.75)
    XCTAssertTrue(primaryActive.isVisible)
    XCTAssertEqual(primaryActive.values, target)
  }

  // MARK: Lifecycle

  func testMissingPlacementRemovesItsSurfacesImmediately() async throws {
    try await render(scene(anchor: windowA))
    try await render(scene(anchor: windowA, masks: [mask(primary)]))
    XCTAssertTrue(factory.surfaces[2].isClosed)
    XCTAssertTrue(factory.surfaces[3].isClosed)
    XCTAssertFalse(server.windows.contains { $0.id == 1002 })
    XCTAssertEqual(scheduler.pendingCount, 1)
  }

  func testStopRemovesEverySurfaceAndCancelsTimers() async throws {
    try await render(scene(anchor: windowA))
    renderer.stop()

    XCTAssertTrue(factory.surfaces.allSatisfy(\.isClosed))
    XCTAssertTrue(visible(factory.surfaces).isEmpty)
    XCTAssertEqual(scheduler.pendingCount, 0)
    scheduler.advance(by: 1)
    XCTAssertTrue(visible(factory.surfaces).isEmpty)

    // Rendering again starts from fresh surfaces.
    try await render(scene(anchor: windowA))
    XCTAssertEqual(factory.surfaces.count, 8)
  }

  func testSurfaceFailureThrowsWithoutLeavingHalfCreatedSurfaces() async throws {
    factory.remainingSurfaces = 3
    do {
      try await render(scene(anchor: windowA))
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? RenderingError, .surfaceUnavailable)
    }
    XCTAssertTrue(primaryActive.isVisible)
    XCTAssertTrue(factory.surfaces[2].isClosed)
  }

  func testUnknownPrimaryDisplayRemovesEffectsAndThrows() async throws {
    try await render(scene(anchor: windowA))
    server.primaryDisplayHeight = nil
    let desktop = DesktopFixtures.overlappingWindows()
    let withoutPrimary = DesktopSnapshot(
      revision: 2, displays: Array(desktop.displays.dropFirst()), windows: desktop.windows,
      focusedWindow: desktop.focusedWindow, focusConfidence: desktop.focusConfidence)
    do {
      try await render(scene(anchor: windowA), desktop: withoutPrimary)
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? RenderingError, .unknownPrimaryDisplay)
    }
    XCTAssertTrue(factory.surfaces.allSatisfy(\.isClosed))
  }
}
