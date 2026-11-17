import Contracts
import Geometry
import TestSupport
import XCTest

@testable import Rules

final class EffectResolverTests: XCTestCase {
  private let resolver = EffectResolver()
  private let primary = DesktopFixtures.primaryID
  private let secondary = DesktopFixtures.secondaryID
  private let primaryFrame = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
  private let secondaryFrame = ScreenRect(x: -1920, y: -100, width: 1920, height: 1080)

  // MARK: - Modes and activation

  func testAllDisplaysAffectsVisibleInactiveWindowOnEveryDisplay() {
    let scene = resolver.resolve(
      desktop: DesktopFixtures.overlappingWindows(revision: 7), session: session())
    XCTAssertEqual(scene.revision, 7)
    XCTAssertEqual(scene.masks.map(\.placement.displayID), [primary, secondary])
    // Entire display areas, including wallpaper, minus the focused window.
    XCTAssertEqual(area(scene, primary), 1440 * 900 - 800 * 600)
    XCTAssertEqual(area(scene, secondary), 1920 * 1080)
    XCTAssertFalse(covers(scene, ScreenPoint(x: 500, y: 400)), "focused window stays sharp")
    XCTAssertTrue(covers(scene, ScreenPoint(x: 50, y: 400)))
    XCTAssertTrue(covers(scene, ScreenPoint(x: -100, y: 400)))
    assertWellFormed(scene, DesktopFixtures.overlappingWindows())
  }

  func testSelectedDisplaysLimitTheEffect() {
    let scene = resolver.resolve(
      desktop: DesktopFixtures.overlappingWindows(),
      session: session(scope: .displays([secondary])))
    XCTAssertEqual(area(scene, primary), 0)
    XCTAssertEqual(area(scene, secondary), 1920 * 1080)
  }

  func testEmptyDisplaySelectionHasNoEffect() {
    let scene = resolver.resolve(
      desktop: DesktopFixtures.overlappingWindows(), session: session(scope: .displays([])))
    XCTAssertEqual(totalArea(scene), 0)
  }

  func testDisabledConfigurationProducesEmptyMasks() {
    let scene = resolver.resolve(
      desktop: DesktopFixtures.overlappingWindows(), session: session(isEnabled: false))
    XCTAssertEqual(scene.masks.map(\.placement.displayID), [primary, secondary])
    XCTAssertTrue(scene.masks.allSatisfy { $0.overlay.isEmpty && $0.anchored.isEmpty })
    XCTAssertNil(scene.anchor)
  }

  func testUnavailableFocusProducesEmptyMasks() {
    let base = DesktopFixtures.overlappingWindows()
    let desktop = DesktopSnapshot(
      revision: 1, displays: base.displays, windows: base.windows,
      focusedWindow: base.focusedWindow, focusConfidence: .unavailable)
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(scene.masks.count, 2)
    XCTAssertEqual(totalArea(scene), 0)
  }

  func testMissingOrUnknownFocusedWindowProducesEmptyMasks() {
    let base = DesktopFixtures.overlappingWindows()
    let stale = WindowReference(windowID: 101, ownerPID: 1001, generation: 2)
    for focused in [nil, stale] {
      let desktop = DesktopSnapshot(
        revision: 1, displays: base.displays, windows: base.windows, focusedWindow: focused,
        focusConfidence: .uncertain)
      XCTAssertEqual(totalArea(resolver.resolve(desktop: desktop, session: session())), 0)
    }
  }

  func testFocusedWindowOffScreenProducesEmptyMasks() {
    let desktop = snapshot(
      windows: [
        WindowSnapshot(
          reference: DesktopFixtures.focused,
          frame: ScreenRect(x: 0, y: 0, width: 100, height: 100),
          isOnScreen: false),
        window(ref(1), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(scene.masks.count, 1)
    XCTAssertEqual(totalArea(scene), 0)
    XCTAssertEqual(anchoredArea(scene), 0)
    XCTAssertNil(scene.anchor)
  }

  func testWallpaperWithoutInactiveWindowsCoversEveryAllowedDisplay() {
    let desktop = snapshot(
      displays: [display(primary, primaryFrame), display(secondary, secondaryFrame)],
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 400, height: 300))
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(area(scene, primary), primaryFrame.area - 400 * 300)
    XCTAssertEqual(mask(scene, secondary)?.overlay, [secondaryFrame])
    XCTAssertEqual(mask(scene, primary)?.anchored, [primaryFrame])
    XCTAssertTrue(covers(scene, ScreenPoint(x: 1000, y: 800)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 200, y: 200)))
    assertWellFormed(scene, desktop)
  }

  func testWallpaperRegionsUnionAndClipProtectedWindowWithoutDoubleEffect() {
    let desktop = snapshot(windows: [
      window(DesktopFixtures.focused, ScreenRect(x: 600, y: 300, width: 400, height: 400))
    ])
    let first = region(primary, NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))
    let scene = resolver.resolve(
      desktop: desktop,
      session: session(scope: .regions, regions: [first, first]))
    XCTAssertEqual(totalArea(scene), 720 * 450 - 120 * 150)
    XCTAssertEqual(
      mask(scene, primary)?.anchored, [ScreenRect(x: 0, y: 0, width: 720, height: 450)])
    XCTAssertTrue(covers(scene, ScreenPoint(x: 100, y: 100)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 650, y: 350)))
    XCTAssertFalse(coversAnchored(scene, ScreenPoint(x: 800, y: 200)))
    assertWellFormed(scene, desktop)
  }

  /// Dock and menu bar draw above the effect surfaces; desktop icons and
  /// widgets belong to the blurred background. None of them cuts a hole.
  func testNonNormalAndSystemSurfacesNeitherCutHolesNorJoinTheAnchor() {
    let desktop = snapshot(windows: [
      WindowSnapshot(
        reference: ref(1), frame: ScreenRect(x: 0, y: 0, width: 1440, height: 30),
        level: 24, isSystemUI: true),
      WindowSnapshot(
        reference: ref(2), frame: ScreenRect(x: 400, y: 800, width: 600, height: 100),
        level: 20, isSystemUI: true),
      window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 200, height: 200)),
      WindowSnapshot(
        reference: ref(3), frame: ScreenRect(x: 1000, y: 100, width: 100, height: 100),
        isSystemUI: true),
      window(ref(4), ScreenRect(x: 1200, y: 100, width: 100, height: 100), level: -1),
    ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [ref(3)]))
    XCTAssertEqual(scene.anchor?.group, [DesktopFixtures.focused], "system UI cannot join anchor")
    for point in [
      ScreenPoint(x: 10, y: 10), ScreenPoint(x: 500, y: 850),
      ScreenPoint(x: 1050, y: 150), ScreenPoint(x: 1250, y: 150),
    ] {
      XCTAssertTrue(covers(scene, point))
      XCTAssertTrue(coversAnchored(scene, point))
    }
    XCTAssertTrue(covers(scene, ScreenPoint(x: 800, y: 500)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 150, y: 150)))
    assertWellFormed(scene, desktop)
  }

  func testAnchoredProtectionBehindGroupRespectsForeignOccluder() {
    let exception = ref(2)
    let desktop = snapshot(windows: [
      window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 400, height: 400)),
      window(ref(1), ScreenRect(x: 100, y: 100, width: 100, height: 100)),
      window(exception, ScreenRect(x: 100, y: 100, width: 200, height: 200)),
    ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [exception]))
    XCTAssertEqual(scene.anchor?.group, [DesktopFixtures.focused])
    XCTAssertFalse(covers(scene, ScreenPoint(x: 150, y: 150)))
    XCTAssertTrue(
      coversAnchored(scene, ScreenPoint(x: 150, y: 150)), "foreign occluder still treated")
    XCTAssertFalse(
      coversAnchored(scene, ScreenPoint(x: 250, y: 250)), "exception below group protected")
    XCTAssertTrue(
      coversAnchored(scene, ScreenPoint(x: 350, y: 350)), "wallpaper below group covered")
    assertWellFormed(scene, desktop)
  }

  // MARK: - Visibility and exceptions

  func testWindowInFrontOfFocusedWindowIsAffectedWhereVisible() {
    let front = ref(1)
    let desktop = snapshot(
      windows: [
        window(front, ScreenRect(x: 0, y: 0, width: 200, height: 200)),
        window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 400, height: 400)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 400 * 400 + 100 * 100)
    XCTAssertTrue(covers(scene, ScreenPoint(x: 150, y: 150)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 300, y: 300)))
  }

  func testHiddenPartsOfBackgroundWindowsAreNotDoubleCovered() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1000, y: 0, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: 0, y: 0, width: 300, height: 300)),
        window(ref(2), ScreenRect(x: 100, y: 100, width: 300, height: 300)),
        window(ref(3), ScreenRect(x: 50, y: 50, width: 100, height: 100)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 100 * 100)
    assertWellFormed(scene, desktop)
  }

  func testVisibleExceptionStaysSharp() {
    let exception = ref(1)
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(exception, ScreenRect(x: 200, y: 0, width: 200, height: 200)),
        window(ref(2), ScreenRect(x: 300, y: 100, width: 200, height: 200)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [exception]))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 250, y: 50)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 350, y: 150)), "exception occludes window behind")
    XCTAssertTrue(covers(scene, ScreenPoint(x: 450, y: 150)))
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 100 * 100 - 200 * 200)
  }

  func testExceptionBehindAnotherWindowRevealsNothing() {
    let exception = ref(2)
    let front = ref(1)
    let behind = ref(3)
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1000, y: 0, width: 100, height: 100)),
        window(front, ScreenRect(x: 0, y: 0, width: 200, height: 200)),
        window(exception, ScreenRect(x: 100, y: 100, width: 200, height: 200)),
        window(behind, ScreenRect(x: 150, y: 150, width: 300, height: 300)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [exception]))
    // Front window covers part of the exception and stays affected there.
    XCTAssertTrue(covers(scene, ScreenPoint(x: 150, y: 150)))
    // Visible remainder of the exception stays sharp.
    XCTAssertFalse(covers(scene, ScreenPoint(x: 250, y: 250)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 150, y: 250)))
    // Content behind the exception is not carved out through the front window.
    XCTAssertTrue(covers(scene, ScreenPoint(x: 400, y: 400)))
    XCTAssertEqual(totalArea(scene), primaryFrame.area - 10_000 - 30_000)
    assertWellFormed(scene, desktop)
  }

  func testExceptionFullyBehindFocusedWindowOnlyJoinsTheGroup() {
    let exception = ref(1)
    let base = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 400, height: 400)),
        window(exception, ScreenRect(x: 50, y: 50, width: 100, height: 100)),
        window(ref(2), ScreenRect(x: 300, y: 300, width: 200, height: 200)),
      ])
    let excepted = resolver.resolve(desktop: base, session: session(exceptions: [exception]))
    let plain = resolver.resolve(desktop: base, session: session())
    XCTAssertEqual(excepted.masks.map(\.overlay), plain.masks.map(\.overlay))
    // Contiguous behind the focused window, the exception becomes the anchor and
    // stays sharp because it is drawn above the anchored surfaces.
    XCTAssertEqual(excepted.anchor?.window, exception)
    XCTAssertTrue(coversAnchored(excepted, ScreenPoint(x: 100, y: 100)))
    XCTAssertTrue(coversAnchored(plain, ScreenPoint(x: 100, y: 100)))
  }

  func testStaleExceptionGenerationDoesNotProtectReusedWindowID() {
    let current = WindowReference(windowID: 9, ownerPID: 90, generation: 2)
    let stale = WindowReference(windowID: 9, ownerPID: 90, generation: 1)
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(current, ScreenRect(x: 200, y: 0, width: 100, height: 100)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [stale]))
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 100 * 100)
  }

  func testAssociatedWindowsStaySharpWhileTheMenuBarCutsNoHole() {
    let dialog = ref(1)
    let menuBar = ref(2)
    let desktop = DesktopSnapshot(
      revision: 1, displays: [display(primary, primaryFrame)],
      windows: [
        WindowSnapshot(
          reference: menuBar, frame: ScreenRect(x: 0, y: 0, width: 1440, height: 30),
          level: 24, isSystemUI: true),
        window(dialog, ScreenRect(x: 400, y: 300, width: 200, height: 100)),
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 500, width: 100, height: 100)),
        window(ref(3), ScreenRect(x: 0, y: 0, width: 1440, height: 900)),
      ],
      focusedWindow: DesktopFixtures.focused, focusConfidence: .uncertain,
      associatedWindows: [dialog])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertTrue(covers(scene, ScreenPoint(x: 10, y: 10)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 500, y: 350)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 50, y: 550)))
    XCTAssertTrue(covers(scene, ScreenPoint(x: 700, y: 700)))
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 200 * 100 - 100 * 100)
  }

  func testOffScreenAndInvalidWindowsNeitherOccludeNorReceiveEffect() {
    let desktop = snapshot(
      windows: [
        WindowSnapshot(
          reference: ref(1), frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900),
          isOnScreen: false),
        window(ref(2), ScreenRect(x: 0, y: 0, width: .nan, height: 900)),
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(ref(3), ScreenRect(x: 0, y: 0, width: 300, height: 300)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 100 * 100)
  }

  // MARK: - Anchor and levels

  func testSheetInFrontAndAssociatedWindowBehindFormTheAnchorGroup() {
    let sheet = ref(1)
    let palette = ref(2)
    let desktop = DesktopSnapshot(
      revision: 1, displays: [display(primary, primaryFrame)],
      windows: [
        window(sheet, ScreenRect(x: 150, y: 100, width: 300, height: 200)),
        window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 400, height: 400)),
        window(palette, ScreenRect(x: 500, y: 100, width: 100, height: 400)),
        window(ref(3), primaryFrame),
      ],
      focusedWindow: DesktopFixtures.focused, focusConfidence: .uncertain,
      associatedWindows: [sheet, palette])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(
      scene.anchor,
      RenderAnchor(window: palette, group: [sheet, DesktopFixtures.focused, palette]))
    // Overlay keeps the group sharp; anchored also covers what the group hides.
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 500 * 400)
    XCTAssertEqual(anchoredArea(scene), 1440 * 900)
    XCTAssertFalse(covers(scene, ScreenPoint(x: 300, y: 300)))
    XCTAssertTrue(coversAnchored(scene, ScreenPoint(x: 300, y: 300)))
    assertWellFormed(scene, desktop)
  }

  func testExceptionContiguousAtTheFrontJoinsTheGroup() {
    let exception = ref(1)
    let desktop = snapshot(
      windows: [
        window(exception, ScreenRect(x: 0, y: 0, width: 200, height: 200)),
        window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 400, height: 400)),
        window(ref(2), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [exception]))
    XCTAssertEqual(
      scene.anchor,
      RenderAnchor(window: DesktopFixtures.focused, group: [exception, DesktopFixtures.focused]))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 50, y: 50)))
    XCTAssertTrue(coversAnchored(scene, ScreenPoint(x: 50, y: 50)))
    assertWellFormed(scene, desktop)
  }

  func testExceptionBehindAForeignWindowDoesNotJoinTheGroup() {
    let exception = ref(2)
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: 200, y: 0, width: 100, height: 100)),
        window(exception, ScreenRect(x: 200, y: 0, width: 300, height: 300)),
        window(ref(3), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session(exceptions: [exception]))
    XCTAssertEqual(
      scene.anchor, RenderAnchor(window: DesktopFixtures.focused, group: [DesktopFixtures.focused]))
    XCTAssertFalse(coversAnchored(scene, ScreenPoint(x: 400, y: 200)), "exception still occludes")
    assertWellFormed(scene, desktop)
  }

  func testForeignNormalWindowAboveFocusedWindowPreventsAnchor() {
    let desktop = snapshot(
      windows: [
        window(ref(1), ScreenRect(x: 0, y: 0, width: 200, height: 200)),
        window(DesktopFixtures.focused, ScreenRect(x: 100, y: 100, width: 400, height: 400)),
        window(ref(2), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertNil(scene.anchor)
    XCTAssertEqual(scene.masks.map(\.anchored), scene.masks.map(\.overlay))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 300, y: 300)))
    assertWellFormed(scene, desktop)
  }

  /// A raised panel draws above every effect surface by itself, so it neither
  /// cuts a hole nor hides the focused window behind it from the masks.
  func testRaisedLevelWindowIsIgnoredByTheMasks() {
    let panel = ref(1)
    let desktop = snapshot(
      windows: [
        window(panel, ScreenRect(x: 0, y: 0, width: 300, height: 300), level: 3),
        window(DesktopFixtures.focused, ScreenRect(x: 200, y: 200, width: 400, height: 400)),
        window(ref(2), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(
      scene.anchor, RenderAnchor(window: DesktopFixtures.focused, group: [DesktopFixtures.focused]))
    XCTAssertTrue(covers(scene, ScreenPoint(x: 50, y: 50)))
    XCTAssertFalse(covers(scene, ScreenPoint(x: 250, y: 250)))
    XCTAssertTrue(coversAnchored(scene, ScreenPoint(x: 250, y: 250)))
    XCTAssertEqual(anchoredArea(scene), 1440 * 900)
    XCTAssertEqual(totalArea(scene), 1440 * 900 - 400 * 400)
    assertWellFormed(scene, desktop)
  }

  /// A raised focused window draws above the overlay surfaces by itself.
  func testFocusedWindowAtRaisedLevelHasNoAnchorAndNoHole() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100), level: 3),
        window(ref(1), primaryFrame),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertNil(scene.anchor)
    XCTAssertEqual(totalArea(scene), 1440 * 900)
  }

  // MARK: - Regions

  func testOverlappingRegionsAreUnionedWithoutDoubleCoverage() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), primaryFrame),
      ])
    let regions = [
      region(primary, NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
      region(primary, NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
      region(primary, NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
    ]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    let quarter = 720.0 * 450
    XCTAssertEqual(totalArea(scene), quarter * 2 - quarter / 4, accuracy: 1e-6)
    assertWellFormed(scene, desktop)
  }

  func testWindowPartiallyInsideRegionIsOnlyAffectedInsideIt() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: 600, y: 300, width: 400, height: 400)),
      ])
    let regions = [region(primary, NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertEqual(
      mask(scene, primary)?.overlay, [ScreenRect(x: 0, y: 0, width: 720, height: 450)])
  }

  func testDisabledAndInvalidRegionsHaveNoEffect() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), primaryFrame),
      ])
    let regions = [
      region(primary, NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5), isEnabled: false),
      region(primary, NormalizedRect(x: 2, y: 0, width: 0.5, height: 0.5)),
      region(primary, NormalizedRect(x: 0, y: 0, width: .nan, height: 0.5)),
    ]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertEqual(totalArea(scene), 0)
  }

  func testRegionsOnSeveralDisplaysStayOnTheirDisplay() {
    let desktop = DesktopFixtures.overlappingWindows()
    let regions = [
      region(secondary, NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)),
      region(primary, NormalizedRect(x: 0, y: 0, width: 0.05, height: 1)),
    ]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertEqual(area(scene, secondary), 960 * 1080)
    XCTAssertEqual(area(scene, primary), 72 * 900)
    assertWellFormed(scene, desktop)
  }

  func testFractionalGeometryYieldsStrictlyDisjointMasks() {
    let thirdFrame = ScreenRect(x: -1366.5, y: -0.25, width: 1366.5, height: 768.75)
    let desktop = snapshot(
      displays: [display(primary, primaryFrame), display(secondary, thirdFrame)],
      windows: [
        window(
          DesktopFixtures.focused, ScreenRect(x: -700.3, y: 100.1, width: 333.3, height: 99.9)),
        window(ref(1), ScreenRect(x: -1200.7, y: 10.01, width: 1500.13, height: 600.6)),
        window(ref(2), ScreenRect(x: -1366.5, y: -0.25, width: 2000, height: 800)),
      ])
    let regions = (1...6).map { index in
      region(
        index.isMultiple(of: 2) ? primary : secondary,
        NormalizedRect(
          x: 1.0 / Double(index + 2), y: 1.0 / Double(index + 5), width: 1.0 / 3,
          height: 2.0 / 7))
    }
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertGreaterThan(totalArea(scene), 0)
    assertWellFormed(scene, desktop)
  }

  // MARK: - Display changes

  func testRegionsOfMissingDisplayArePausedNotMoved() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), primaryFrame),
      ])
    let regions = [region(secondary, NormalizedRect(x: 0, y: 0, width: 1, height: 1))]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertEqual(scene.masks.map(\.placement.displayID), [primary])
    XCTAssertEqual(totalArea(scene), 0)
  }

  func testSelectedDisplayThatDisappearedHasNoEffect() {
    let desktop = snapshot(
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), primaryFrame),
      ])
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .displays([secondary])))
    XCTAssertEqual(totalArea(scene), 0)
  }

  func testRegionFollowsItsDisplayAfterRearrangementAndResolutionChange() {
    let moved = ScreenRect(x: 1440, y: 200, width: 2560, height: 1440)
    let desktop = DesktopSnapshot(
      revision: 2, displays: [display(primary, primaryFrame), display(secondary, moved)],
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: 0, y: 0, width: 5000, height: 2000)),
      ],
      focusedWindow: DesktopFixtures.focused, focusConfidence: .uncertain)
    let regions = [region(secondary, NormalizedRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))]
    let scene = resolver.resolve(
      desktop: desktop, session: session(scope: .regions, regions: regions))
    XCTAssertEqual(
      mask(scene, secondary)?.overlay,
      [ScreenRect(x: 1440 + 1280, y: 200 + 720, width: 640, height: 360)])
    XCTAssertEqual(area(scene, primary), 0)
  }

  private func ambiguousDesktop() -> DesktopSnapshot {
    DesktopSnapshot(
      revision: 1,
      displays: [
        display(primary, primaryFrame),
        display(secondary, ScreenRect(x: 1440, y: 0, width: 1440, height: 900), runtimeID: 2),
        display(secondary, ScreenRect(x: 2880, y: 0, width: 1440, height: 900), runtimeID: 3),
      ],
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: 0, y: 0, width: 4320, height: 900)),
      ],
      focusedWindow: DesktopFixtures.focused, focusConfidence: .uncertain)
  }

  func testAllDisplaysScopeStillCoversAmbiguousDisplayIDs() {
    let scene = resolver.resolve(desktop: ambiguousDesktop(), session: session())
    XCTAssertEqual(scene.masks.map(\.placement.displayID), [primary, secondary, secondary])
    XCTAssertEqual(scene.masks.map(\.placement.runtimeID), [1, 2, 3])
    XCTAssertEqual(Set(scene.masks.map(\.placement)).count, 3)
    XCTAssertEqual(
      scene.masks.filter { $0.placement.displayID == secondary }.map(\.overlay),
      [
        [ScreenRect(x: 1440, y: 0, width: 1440, height: 900)],
        [ScreenRect(x: 2880, y: 0, width: 1440, height: 900)],
      ])
    XCTAssertEqual(totalArea(scene), 4320 * 900 - 100 * 100)
    assertWellFormed(scene, ambiguousDesktop())
  }

  func testDuplicateRuntimeIDsAreDroppedInsteadOfGuessed() {
    let desktop = snapshot(
      displays: [
        display(primary, primaryFrame, runtimeID: 7),
        display(secondary, secondaryFrame, runtimeID: 7),
      ],
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 0, y: 0, width: 100, height: 100)),
        window(ref(1), primaryFrame),
      ])
    XCTAssertEqual(resolver.resolve(desktop: desktop, session: session()).masks, [])
  }

  func testDisplayBoundScopesPauseAmbiguousDisplayIDs() {
    let regions = [region(secondary, NormalizedRect(x: 0, y: 0, width: 1, height: 1))]
    for scope in [EffectScope.displays([primary, secondary]), .regions] {
      let scene = resolver.resolve(
        desktop: ambiguousDesktop(), session: session(scope: scope, regions: regions))
      XCTAssertEqual(scene.masks.map(\.placement.displayID), [primary], "\(scope)")
      XCTAssertEqual(mask(scene, secondary)?.overlay, nil, "\(scope)")
    }
  }

  func testWindowSpanningDisplaysIsClippedPerDisplay() {
    let desktop = snapshot(
      displays: [display(primary, primaryFrame), display(secondary, secondaryFrame)],
      windows: [
        window(DesktopFixtures.focused, ScreenRect(x: 1300, y: 800, width: 100, height: 100)),
        window(ref(1), ScreenRect(x: -500, y: -300, width: 1000, height: 600)),
      ])
    let scene = resolver.resolve(desktop: desktop, session: session())
    XCTAssertEqual(area(scene, primary), 1440 * 900 - 100 * 100)
    XCTAssertEqual(mask(scene, secondary)?.overlay, [secondaryFrame])
    assertWellFormed(scene, desktop)
  }

  // MARK: - Reference model

  func testMatchesPointSamplingReferenceOnRandomDesktops() {
    var random = SeededRandom(seed: 42)
    var anchoredScenes = 0
    for iteration in 0..<60 {
      let windows = (0..<7).map { index in
        WindowSnapshot(
          reference: ref(UInt32(index)),
          frame: ScreenRect(
            x: Double(random.next(in: -2000...1400)), y: Double(random.next(in: -150...850)),
            width: Double(random.next(in: 20...900)), height: Double(random.next(in: 20...600))),
          level: random.next(in: 0...7) == 0 ? (iteration.isMultiple(of: 2) ? -1 : 3) : 0,
          isOnScreen: random.next(in: 0...9) > 0,
          isSystemUI: random.next(in: 0...9) == 0)
      }
      let focused = windows[random.next(in: 0...2)].reference
      let associated = Set(windows.filter { _ in random.next(in: 0...5) == 0 }.map(\.reference))
      let exceptions = Set(windows.filter { _ in random.next(in: 0...3) == 0 }.map(\.reference))
      let regions = (0..<3).map { _ in
        region(
          random.next(in: 0...1) == 0 ? primary : secondary,
          NormalizedRect(
            x: Double(random.next(in: -10...90)) / 100, y: Double(random.next(in: -10...90)) / 100,
            width: Double(random.next(in: 5...60)) / 100,
            height: Double(random.next(in: 5...60)) / 100),
          isEnabled: random.next(in: 0...4) > 0)
      }
      let scopes: [EffectScope] = [.allDisplays, .displays([secondary]), .regions]
      let scope = scopes[iteration % scopes.count]
      let desktop = DesktopSnapshot(
        revision: UInt64(iteration),
        displays: [display(primary, primaryFrame), display(secondary, secondaryFrame)],
        windows: windows, focusedWindow: focused, focusConfidence: .uncertain,
        associatedWindows: associated)
      let currentSession = session(scope: scope, regions: regions, exceptions: exceptions)
      let scene = resolver.resolve(desktop: desktop, session: currentSession)
      assertWellFormed(scene, desktop)
      if scene.anchor != nil { anchoredScenes += 1 }
      if desktop.windows.contains(where: { $0.reference == focused && $0.isOnScreen }) {
        XCTAssertEqual(
          scene.anchor?.group, referenceGroup(desktop: desktop, session: currentSession),
          "iteration \(iteration)")
      }

      for x in stride(from: -1995.0, to: 1440, by: 37) {
        for y in stride(from: -95.0, to: 900, by: 23) {
          let point = ScreenPoint(x: x, y: y)
          let expected = referenceCovers(point, desktop: desktop, session: currentSession)
          XCTAssertEqual(covers(scene, point), expected, "iteration \(iteration) at \(point)")
          let expectedAnchored = referenceCovers(
            point, desktop: desktop, session: currentSession, anchored: true)
          XCTAssertEqual(
            coversAnchored(scene, point), expectedAnchored,
            "anchored iteration \(iteration) at \(point)")
        }
      }
    }
    XCTAssertGreaterThan(anchoredScenes, 10, "random desktops must exercise anchors")
  }

  // MARK: - Helpers

  /// Point-sampling reference, independent of the region algebra. With
  /// `anchored`, windows of the front group do not occlude.
  private func referenceCovers(
    _ point: ScreenPoint, desktop: DesktopSnapshot, session: FocusSession, anchored: Bool = false
  ) -> Bool {
    guard
      desktop.windows.contains(where: { $0.reference == desktop.focusedWindow && $0.isOnScreen }),
      let display = desktop.displays.first(where: { inside(point, $0.frame) })
    else { return false }
    let inScope: Bool
    switch session.configuration.scope {
    case .allDisplays: inScope = true
    case .displays(let ids): inScope = ids.contains(display.id)
    case .regions:
      inScope = session.configuration.regions.contains { region in
        region.isEnabled && region.displayID == display.id
          && DisplayGeometry.screenRect(for: region.rect, on: display).map { inside(point, $0) }
            == true
      }
    }
    let group = anchored ? referenceGroup(desktop: desktop, session: session) ?? [] : []
    guard inScope else { return false }
    // Only normal app windows matter; everything else is above or below.
    guard
      let top = desktop.windows.first(where: {
        $0.isOnScreen && $0.level == 0 && !$0.isSystemUI && inside(point, $0.frame)
          && !group.contains($0.reference)
      })
    else { return true }  // Uncovered background receives the effect.
    return !isProtected(top.reference, desktop: desktop, session: session)
  }

  private func referenceGroup(desktop: DesktopSnapshot, session: FocusSession)
    -> Set<WindowReference>?
  {
    let normal = desktop.windows.filter {
      $0.isOnScreen && $0.frame.isUsable && $0.level == 0 && !$0.isSystemUI
    }
    let prefix = normal.prefix { isProtected($0.reference, desktop: desktop, session: session) }
    let group = Set(prefix.map(\.reference))
    return desktop.focusedWindow.map(group.contains) == true ? group : nil
  }

  private func isProtected(
    _ reference: WindowReference, desktop: DesktopSnapshot, session: FocusSession
  ) -> Bool {
    reference == desktop.focusedWindow || desktop.associatedWindows.contains(reference)
      || session.exceptions.contains(reference)
  }

  private func assertWellFormed(
    _ scene: RenderScene, _ desktop: DesktopSnapshot, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      Set(scene.masks.map(\.placement.runtimeID)).count, scene.masks.count, file: file,
      line: line)
    for mask in scene.masks {
      let frame = mask.placement.frame
      XCTAssertTrue(
        desktop.displays.contains {
          $0.runtimeID == mask.placement.runtimeID && $0.id == mask.placement.displayID
        }, "mask for unknown display", file: file, line: line)
      for rectangles in [mask.anchored, mask.overlay] {
        for (index, rect) in rectangles.enumerated() {
          XCTAssertTrue(rect.isUsable, file: file, line: line)
          XCTAssertTrue(frame.contains(rect), "\(rect) outside \(frame)", file: file, line: line)
          for other in rectangles[(index + 1)...] {
            XCTAssertNil(rect.intersection(other), "double coverage", file: file, line: line)
          }
        }
      }
      XCTAssertTrue(
        ScreenRegion(unioning: mask.overlay).subtracting(ScreenRegion(unioning: mask.anchored))
          .isEmpty, "anchored must cover overlay", file: file, line: line)
      if scene.anchor == nil {
        XCTAssertEqual(mask.anchored, mask.overlay, file: file, line: line)
      }
    }
  }

  private func inside(_ point: ScreenPoint, _ rect: ScreenRect) -> Bool {
    rect.isUsable && point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY
      && point.y < rect.maxY
  }

  private func covers(_ scene: RenderScene, _ point: ScreenPoint) -> Bool {
    scene.masks.contains { mask in mask.overlay.contains { inside(point, $0) } }
  }

  private func coversAnchored(_ scene: RenderScene, _ point: ScreenPoint) -> Bool {
    scene.masks.contains { mask in mask.anchored.contains { inside(point, $0) } }
  }

  private func mask(_ scene: RenderScene, _ id: DisplayID) -> DisplayEffectMask? {
    scene.masks.first { $0.placement.displayID == id }
  }

  private func area(_ scene: RenderScene, _ id: DisplayID) -> Double {
    mask(scene, id)?.overlay.reduce(0) { $0 + $1.area } ?? 0
  }

  private func totalArea(_ scene: RenderScene) -> Double {
    scene.masks.flatMap(\.overlay).reduce(0) { $0 + $1.area }
  }

  private func anchoredArea(_ scene: RenderScene) -> Double {
    scene.masks.flatMap(\.anchored).reduce(0) { $0 + $1.area }
  }

  private func ref(_ id: UInt32) -> WindowReference {
    WindowReference(windowID: 500 + id, ownerPID: 5000 + Int32(id), generation: 1)
  }

  private func window(_ reference: WindowReference, _ frame: ScreenRect, level: Int = 0)
    -> WindowSnapshot
  {
    WindowSnapshot(reference: reference, frame: frame, level: level)
  }

  private func display(_ id: DisplayID, _ frame: ScreenRect, runtimeID: UInt32? = nil)
    -> DisplaySnapshot
  {
    DisplaySnapshot(
      id: id, runtimeID: runtimeID ?? (id == primary ? 1 : 2), name: id.rawValue, frame: frame,
      scale: 2)
  }

  private func region(_ id: DisplayID, _ rect: NormalizedRect, isEnabled: Bool = true)
    -> FocusRegion
  {
    FocusRegion(displayID: id, rect: rect, isEnabled: isEnabled)
  }

  private func snapshot(displays: [DisplaySnapshot]? = nil, windows: [WindowSnapshot])
    -> DesktopSnapshot
  {
    DesktopSnapshot(
      revision: 1, displays: displays ?? [display(primary, primaryFrame)], windows: windows,
      focusedWindow: DesktopFixtures.focused, focusConfidence: .uncertain)
  }

  private func session(
    isEnabled: Bool = true, scope: EffectScope = .allDisplays, regions: [FocusRegion] = [],
    effects: EffectSettings = EffectSettings(), exceptions: Set<WindowReference> = []
  ) -> FocusSession {
    FocusSession(
      configuration: FocusConfiguration(
        isEnabled: isEnabled, scope: scope, regions: regions, effects: effects),
      exceptions: exceptions)
  }
}

private struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next(in range: ClosedRange<Int>) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let span = UInt64(range.upperBound - range.lowerBound + 1)
    return range.lowerBound + Int((state >> 33) % span)
  }
}
