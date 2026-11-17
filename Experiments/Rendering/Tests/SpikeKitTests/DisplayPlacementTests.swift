import AppKit
import XCTest

@testable import SpikeKit

final class DisplayPlacementTests: XCTestCase {
  let screens = [
    CGRect(x: 0, y: 0, width: 1000, height: 800),
    CGRect(x: -1000, y: -200, width: 1000, height: 900),
    CGRect(x: 1000, y: 100, width: 800, height: 600),
  ]

  func win(_ id: UInt32, _ rect: CGRect, layer: Int = 0) -> CGWin {
    CGWin(id: id, pid: Int32(id), owner: "test", layer: layer, bounds: rect)
  }

  func testTwoAndThreeDisplaysFocusPrimarySecondaryAndSpanning() {
    for count in [2, 3] {
      for focusRect in [
        CGRect(x: 50, y: 50, width: 300, height: 300),
        CGRect(x: -800, y: -100, width: 300, height: 300),
        CGRect(x: -100, y: 50, width: 300, height: 300),
      ] {
        let focus = win(1, focusRect)
        let global = Anchoring.plan(frontToBack: [focus], focused: focus)
        let local = screens.prefix(count).map { DisplayPlacement.plan(global, screen: $0) }
        for (screen, plan) in zip(screens, local) {
          XCTAssertEqual(plan.anchor != nil, focusRect.intersects(screen))
          XCTAssertEqual(plan.groupIDs, [1])
          if plan.anchor == nil {
            let path = MaskPath.painter(
              pieces: [MaskPiece(rect: screen, kind: .effect)]
                + Anchoring.scopeHoles(for: plan, exceptions: []),
              screen: screen, cornerRadius: 0, flipped: true)
            let overlap = focusRect.intersection(screen)
            if !overlap.isNull {
              XCTAssertFalse(
                path.contains(CGPoint(x: overlap.midX - screen.minX, y: overlap.midY - screen.minY))
              )
            }
          }
        }
      }
    }
  }

  func testMissingMisplacedIdentityAndPerDisplayFailure() {
    let focus = win(1, CGRect(x: -100, y: 50, width: 300, height: 300))
    let global = Anchoring.plan(frontToBack: [focus], focused: focus)
    let panel = win(8, screens[0])
    let otherPanel = win(9, screens[1], layer: 1)
    let own: Set<CGWindowID> = [8, 9]
    func verified(_ all: [CGWin], runtime: UInt32? = 10) -> Bool {
      DisplayPlacement.verify(
        frontToBack: all, panelID: 8, ownIDs: own,
        expected: screens[0], displayID: 10, actualDisplayID: runtime, plan: global)
    }
    // Own overlays do not invalidate the local anchor.
    XCTAssertTrue(verified([otherPanel, focus, panel]))
    XCTAssertFalse(verified([focus, otherPanel]))
    XCTAssertFalse(verified([focus, win(8, screens[1])]))
    XCTAssertFalse(verified([focus, panel], runtime: 11))
    XCTAssertFalse(verified([focus, panel], runtime: nil))
    XCTAssertFalse(verified([panel, focus]))  // Never regress all-panels/group protection.
    let inactive = win(3, CGRect(x: 500, y: 100, width: 100, height: 100))
    XCTAssertFalse(verified([focus, inactive, panel]))
    var firstCache = AnchorFailureCache()
    var secondCache = AnchorFailureCache()
    firstCache.record(global)
    XCTAssertNil(firstCache.applying(to: global).anchor)
    XCTAssertEqual(secondCache.applying(to: global).anchor?.id, 1)
    let fallback = firstCache.applying(to: global)
    let path = MaskPath.painter(
      pieces: [MaskPiece(rect: screens[0], kind: .effect)]
        + Anchoring.scopeHoles(for: fallback, exceptions: []), screen: screens[0], cornerRadius: 0,
      flipped: true)
    XCTAssertFalse(path.contains(CGPoint(x: 0, y: 60)))
    XCTAssertTrue(path.contains(CGPoint(x: 500, y: 500)))
    XCTAssertTrue(
      DisplayPlacement.verify(
        frontToBack: [win(8, screens[0], layer: 1), focus],
        panelID: 8, ownIDs: own, expected: screens[0], displayID: 10, actualDisplayID: 10,
        plan: fallback))
    XCTAssertFalse(
      DisplayPlacement.verify(
        frontToBack: [focus, panel],
        panelID: 8, ownIDs: own, expected: screens[0], displayID: 10, actualDisplayID: 10,
        plan: fallback))
  }

  func testMenuFadePointsBoundsOrientationAndClamp() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let fade = MenuFade(bounds: bounds, menuInset: 24, points: 24)
    XCTAssertEqual(fade.opacity(distanceBelowTop: -1), 0)
    XCTAssertEqual(fade.opacity(distanceBelowTop: 0), 0)
    XCTAssertEqual(fade.opacity(distanceBelowTop: 12), 0.5)
    XCTAssertEqual(fade.opacity(distanceBelowTop: 24), 1)
    XCTAssertEqual(fade.opacity(distanceBelowTop: 900), 1)
    XCTAssertEqual(fade.startPoint.y, 1)
    XCTAssertEqual(fade.endPoint.y, 0.97)
    let flipped = MenuFade(bounds: bounds, menuInset: 24, points: 24, topInset: 24, flipped: true)
    XCTAssertEqual(flipped.startPoint.y, 0.03)
    XCTAssertEqual(flipped.endPoint.y, 0.06)
    for points: CGFloat in [0, -1, .nan, .infinity] {
      XCTAssertEqual(MenuFade(bounds: bounds, menuInset: 24, points: points).height, 0)
    }
    XCTAssertEqual(MenuFade(bounds: bounds, menuInset: 0, points: 24).height, 0)
    XCTAssertEqual(MenuFade(bounds: bounds, menuInset: 24, points: 900).height, 800)
    XCTAssertEqual(
      MenuFade(bounds: bounds, menuInset: 24, points: 0).opacity(distanceBelowTop: 0), 1)
  }

  @MainActor
  func testGeometryAndGradientComposeForEffectAndHost() {
    let frame = screens[0]
    let display = DisplayInfo(
      displayID: 10, name: "synthetic", uuid: "test", appKitFrame: frame,
      quartzBounds: frame, scale: 2, pixelSize: CGSize(width: 2000, height: 1600), isMain: true,
      menuBarInset: 24)
    for host in [false, true] {
      let surface = MaskedEffectSurface(
        display: display, material: .hudWindow, alpha: 1,
        dimAlpha: 0.3, maskOnHost: host, menuFade: 24)
      let path = CGPath(rect: CGRect(x: 200, y: 200, width: 300, height: 300), transform: nil)
      surface.apply(path: path)
      XCTAssertTrue(surface.isMaskAttached)
      XCTAssertEqual(surface.effectMask.path, path)
      XCTAssertEqual(surface.dimMask.path, path)
      let blur = surface.effectMask.mask as? CAGradientLayer
      let dim = surface.dimMask.mask as? CAGradientLayer
      XCTAssertEqual(blur?.frame, frame)
      XCTAssertEqual(blur?.startPoint, dim?.startPoint)
      XCTAssertEqual(blur?.endPoint, dim?.endPoint)
      XCTAssertEqual(blur?.endPoint.y, 0.97)
      surface.apply(path: nil)
      XCTAssertTrue(surface.isMaskAttached)
      XCTAssertNotNil(surface.effectMask.mask)
      XCTAssertTrue(surface.effectMask.path?.contains(CGPoint(x: 10, y: 10)) == true)
      surface.applyNative(path: path, fade: MenuFade(bounds: frame, menuInset: 24, points: 24))
      XCTAssertNotNil(surface.effect.maskImage)
      XCTAssertNil(surface.effect.layer?.mask)
      XCTAssertNil(surface.host.layer?.mask)
      XCTAssertNotNil(surface.dim.layer?.mask?.contents)
      surface.apply(path: path)
      XCTAssertNil(surface.effect.maskImage)
      XCTAssertTrue(surface.isMaskAttached)
    }
  }
  func testFullScopeDoesNotPunchUnselectedDesktopOrSystemFrames() {
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    let focus = win(1, CGRect(x: -200, y: 0, width: 50, height: 50))
    let widget = CGWin(
      id: 2, pid: 2, owner: "localized name", layer: -1,
      bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
      bundleID: "com.apple.notificationcenterui")
    let system = CGWin(
      id: 3, pid: 3, owner: "system", layer: -1,
      bounds: CGRect(x: 60, y: 60, width: 20, height: 20))
    let banner = CGWin(
      id: 4, pid: 2, owner: "localized name", layer: 10,
      bounds: CGRect(x: 40, y: 10, width: 20, height: 20),
      bundleID: "com.apple.notificationcenterui")
    XCTAssertTrue(widget.isDesktopWidget)
    XCTAssertFalse(system.isDesktopWidget)
    XCTAssertFalse(banner.isDesktopWidget)
    let plan = DisplayPlacement.plan(
      Anchoring.plan(
        frontToBack: [banner, focus, widget, system], focused: focus), screen: screen)
    let path = MaskPath.painter(
      pieces: [MaskPiece(rect: screen, kind: .effect)]
        + Anchoring.scopeHoles(for: plan, exceptions: []), screen: screen, cornerRadius: 0,
      flipped: true)
    XCTAssertTrue(path.contains(CGPoint(x: 20, y: 20)))
    XCTAssertTrue(path.contains(CGPoint(x: 70, y: 70)))
    // Banner is composited ABOVE the panel; its large bounds must not punch a hole below.
    XCTAssertTrue(path.contains(CGPoint(x: 50, y: 20)))
  }

  @MainActor
  func testNativeMaskPixelsComposeGeometryFadeAndBackingScale() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let path = CGPath(rect: bounds, transform: nil).subtracting(
      CGPath(rect: CGRect(x: 40, y: 40, width: 20, height: 20), transform: nil))
    for scale in [1, 2] {
      for fadePoints: CGFloat in [0, 20] {
        let fade = MenuFade(bounds: bounds, menuInset: 30, points: fadePoints)
        let image = NativeEffectMask.image(path: path, fade: fade, scale: CGFloat(scale))
        XCTAssertEqual(image.representations.first?.pixelsWide, 100 * scale)
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 100 * scale,
          pixelsHigh: 100 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
          bitmap.colorAt(x: x * scale, y: y * scale)!.alphaComponent
        }
        XCTAssertLessThan(alpha(50, 50), 0.01)
        XCTAssertGreaterThan(alpha(10, 90), 0.99)
        if fadePoints == 0 {
          XCTAssertGreaterThan(alpha(10, 0), 0.99)
        } else {
          XCTAssertLessThan(alpha(10, 0), 0.06)
          XCTAssertEqual(alpha(10, 10), 0.5, accuracy: 0.06)
        }
      }
    }
  }

  @MainActor
  func testFullScopeFadeDoesNotRevealBrightChromeBelowMenuBar() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    for scale: CGFloat in [1, 2] {
      for inset: CGFloat in [24, 33] {
        for requested: CGFloat in [0, 12, 24, 80] {
          let fade = MenuFade.insideMenuBar(bounds: bounds, menuInset: inset, points: requested)
          XCTAssertLessThanOrEqual(fade.topInset + fade.height, inset)
          let image = NativeEffectMask.image(
            path: CGPath(rect: bounds, transform: nil), fade: fade, scale: scale)
          let bitmap = image.representations.first as! NSBitmapImageRep
          // Bitmap rows start at the top. Every content pixel must receive the
          // full effect, including the first row below the menu strip.
          for row in [Int(inset * scale), Int((inset + 1) * scale), Int(90 * scale)] {
            XCTAssertGreaterThan(bitmap.colorAt(x: Int(10 * scale), y: row)!.alphaComponent, 0.99)
          }
        }
      }
    }
    XCTAssertEqual(MenuFade.insideMenuBar(bounds: bounds, menuInset: 0, points: 24).height, 0)
  }

}
