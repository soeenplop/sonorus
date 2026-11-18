import Foundation
import XCTest

@testable import Contracts

final class ConfigurationTests: XCTestCase {
  func testMultipleRegionsAndSelectedDisplaysSurvivePersistenceRoundTrip() throws {
    let display = DisplayID(rawValue: "persistent-display")
    let configuration = FocusConfiguration(
      isEnabled: true, scope: .displays([display]),
      regions: [
        FocusRegion(
          displayID: display, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)),
        FocusRegion(
          displayID: display, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
          isEnabled: false),
      ])

    let encoded = try JSONEncoder().encode(configuration)
    XCTAssertEqual(try JSONDecoder().decode(FocusConfiguration.self, from: encoded), configuration)
  }

  func testUntrustedStoredEffectValuesCannotEscapeSupportedBounds() throws {
    let json = Data(#"{"blur":9,"backgroundBrightness":-2,"transitionDuration":100}"#.utf8)
    let effects = try JSONDecoder().decode(EffectSettings.self, from: json)
    XCTAssertEqual(effects.blur, 1)
    XCTAssertEqual(effects.backgroundBrightness, 0)
    XCTAssertEqual(effects.transitionDuration, 1.5)
  }

  func testNonFiniteSliderInputProducesFiniteSettings() {
    let effects = EffectSettings(
      blur: .nan, backgroundBrightness: .infinity, transitionDuration: -.infinity)
    XCTAssertTrue(effects.blur.isFinite)
    XCTAssertTrue(effects.backgroundBrightness.isFinite)
    XCTAssertTrue(effects.transitionDuration.isFinite)
  }

  func testGlobalCoordinatesAllowLeftAndUpperDisplaysButRejectInvalidFrames() {
    XCTAssertTrue(ScreenRect(x: -1920, y: -100, width: 1920, height: 1080).isUsable)
    XCTAssertFalse(ScreenRect(x: 0, y: 0, width: 0, height: 100).isUsable)
    XCTAssertFalse(ScreenRect(x: .nan, y: 0, width: 100, height: 100).isUsable)
  }
}

final class TolerantDecodingTests: XCTestCase {
  func testMissingFieldsFallBackToDefaults() throws {
    let configuration = try JSONDecoder().decode(
      FocusConfiguration.self, from: Data(#"{"isEnabled":true,"effects":{"blur":0.9}}"#.utf8))
    XCTAssertTrue(configuration.isEnabled)
    XCTAssertEqual(configuration.scope, .allDisplays)
    XCTAssertEqual(configuration.regions, [])
    XCTAssertEqual(configuration.effects, EffectSettings(blur: 0.9))
  }

  func testUnreadableRegionIsDroppedAlone() throws {
    let json = #"""
      {"scope":{"regions":{}},"regions":[
        {"id":"00000000-0000-0000-0000-000000000001","displayID":"d",
         "rect":{"x":0.1,"y":0.1,"width":0.5,"height":0.5}},
        {"id":"broken"},
        {"id":"00000000-0000-0000-0000-000000000002","displayID":"d",
         "rect":{"x":0.2,"y":0.2,"width":0.5,"height":0.5},"isEnabled":false}
      ]}
      """#
    let configuration = try JSONDecoder().decode(FocusConfiguration.self, from: Data(json.utf8))
    XCTAssertEqual(configuration.scope, .regions)
    XCTAssertEqual(configuration.regions.map(\.isEnabled), [true, false])
  }

  func testUnknownScopeFallsBackWithoutLosingRegions() throws {
    let json = #"""
      {"scope":{"future":{}},"regions":[
        {"id":"00000000-0000-0000-0000-000000000001","displayID":"d",
         "rect":{"x":0.1,"y":0.1,"width":0.5,"height":0.5}}
      ]}
      """#
    let configuration = try JSONDecoder().decode(FocusConfiguration.self, from: Data(json.utf8))
    XCTAssertEqual(configuration.scope, .allDisplays)
    XCTAssertEqual(configuration.regions.count, 1)
  }
}
