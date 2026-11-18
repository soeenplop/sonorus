import Contracts
import XCTest

@testable import MenuBar

@MainActor
final class MenuBarViewModelTests: XCTestCase {
  private let left = DisplayID(rawValue: "left")
  private let right = DisplayID(rawValue: "right")
  private let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

  private func makeModel(
    state: MenuBarState = MenuBarState(), sleeper: ManualSleeper = ManualSleeper()
  ) -> (MenuBarViewModel, RecordingController, ManualSleeper) {
    let controller = RecordingController()
    let model = MenuBarViewModel(
      controller: controller, state: state, sleep: { try await sleeper.sleep($0) })
    return (model, controller, sleeper)
  }

  private func state(
    scope: EffectScope = .allDisplays, regions: [FocusRegion] = [],
    displays: [MenuBarDisplay] = [], isEnabled: Bool = false
  ) -> MenuBarState {
    MenuBarState(
      configuration: FocusConfiguration(isEnabled: isEnabled, scope: scope, regions: regions),
      displays: displays)
  }

  // MARK: Value mapping

  func testPercentAndDurationText() {
    XCTAssertEqual(EffectFormatting.percent(0), "0%")
    XCTAssertEqual(EffectFormatting.percent(0.7), "70%")
    XCTAssertEqual(EffectFormatting.percent(1), "100%")
    XCTAssertEqual(EffectFormatting.duration(0), "0 ms")
    XCTAssertEqual(EffectFormatting.duration(0.75), "750 ms")
    XCTAssertEqual(EffectFormatting.duration(0.999), "999 ms")
    XCTAssertEqual(EffectFormatting.duration(1), "1.0 s")
    XCTAssertEqual(EffectFormatting.duration(1.25), "1.25 s")
    XCTAssertEqual(EffectFormatting.duration(1.5), "1.5 s")
  }

  func testSettersClampToTheEffectBounds() {
    let (model, controller, _) = makeModel()
    model.setBlur(2)
    model.setBackgroundBrightness(-1)
    model.setTransitionDuration(9)
    XCTAssertEqual(
      model.effects, EffectSettings(blur: 1, backgroundBrightness: 0, transitionDuration: 1.5))
    XCTAssertEqual(controller.calls.count, 3)
  }

  // MARK: Live apply and debounced persistence

  func testEveryChangeIsPreviewedButNotSavedImmediately() {
    let (model, controller, _) = makeModel()
    model.setBlur(0.2)
    model.setBlur(0.3)
    XCTAssertEqual(
      controller.calls,
      [
        .preview(EffectSettings(blur: 0.2)),
        .preview(EffectSettings(blur: 0.3)),
      ])
    XCTAssertTrue(model.hasPendingCommit)
  }

  func testChangesWithoutEffectDoNotSchedulePersistence() {
    let (model, controller, _) = makeModel()
    model.setBlur(0.5)
    XCTAssertTrue(controller.calls.isEmpty)
    XCTAssertFalse(model.hasPendingCommit)
  }

  func testBurstIsSavedOnceWithTheLastValueAfterTheDebounce() async {
    let (model, controller, sleeper) = makeModel()
    model.setBlur(0.2)
    await sleeper.waitForSleeper()
    model.setBlur(0.4)
    model.setTransitionDuration(0.25)
    await sleeper.waitForSleeper()
    XCTAssertTrue(controller.commits.isEmpty)

    sleeper.fire()
    await model.commitTask?.value
    XCTAssertEqual(
      controller.commits, [EffectSettings(blur: 0.4, transitionDuration: 0.25)])
    XCTAssertFalse(model.hasPendingCommit)
  }

  func testChangeAfterASaveStartsANewDebounce() async {
    let (model, controller, sleeper) = makeModel()
    model.setBlur(0.2)
    await sleeper.waitForSleeper()
    sleeper.fire()
    await model.commitTask?.value
    model.setBlur(0.9)
    await sleeper.waitForSleeper()
    sleeper.fire()
    await model.commitTask?.value
    XCTAssertEqual(controller.commits, [EffectSettings(blur: 0.2), EffectSettings(blur: 0.9)])
  }

  func testFlushSavesImmediatelyAndOnlyOnce() async {
    let (model, controller, sleeper) = makeModel()
    model.setBackgroundBrightness(0.3)
    await sleeper.waitForSleeper()
    model.flushPendingCommit()
    model.flushPendingCommit()
    XCTAssertEqual(controller.commits, [EffectSettings(backgroundBrightness: 0.3)])
    XCTAssertEqual(sleeper.waiterCount, 0, "the debounce wait is cancelled")
  }

  func testQuitSavesPendingChangesFirst() {
    let (model, controller, _) = makeModel()
    model.setBlur(0.1)
    model.quit()
    XCTAssertEqual(controller.calls.suffix(2), [.commit(EffectSettings(blur: 0.1)), .quit])
  }

  func testStateFromTheAppDoesNotOverwriteAnUnsavedSliderValue() {
    let (model, _, _) = makeModel()
    model.setBlur(0.9)
    model.apply(state())  // stale blur 0.5 arrives during the drag
    XCTAssertEqual(model.effects.blur, 0.9)
  }

  func testStateFromTheAppIsTakenOverOnceSaved() {
    let (model, _, _) = makeModel()
    model.setBlur(0.9)
    model.flushPendingCommit()
    model.apply(state())
    XCTAssertEqual(model.effects.blur, 0.5)
  }

  // MARK: Main switch and scope

  func testSwitchUpdatesLocallyAndNotifiesTheController() {
    let (model, controller, _) = makeModel()
    model.setEnabled(true)
    XCTAssertTrue(model.isEnabled)
    XCTAssertEqual(controller.calls, [.setEnabled(true)])
  }

  func testScopeChoiceFollowsTheConfiguration() {
    XCTAssertEqual(makeModel(state: state(scope: .allDisplays)).0.scopeChoice, .allDisplays)
    XCTAssertEqual(makeModel(state: state(scope: .displays([left]))).0.scopeChoice, .displays)
    XCTAssertEqual(makeModel(state: state(scope: .regions)).0.scopeChoice, .regions)
  }

  func testSelectionButtonStartsTheSelectionOfTheChosenScope() {
    for (scope, mode): (EffectScope, SelectionMode?) in [
      (.allDisplays, nil), (.displays([]), .displays), (.regions, .regions),
    ] {
      let (model, controller, _) = makeModel(state: state(scope: scope))
      model.startScopeSelection()
      XCTAssertEqual(controller.calls, mode.map { [.startSelection($0)] } ?? [])
      XCTAssertEqual(model.selectionButtonTitle == nil, mode == nil)
    }
  }

  func testRegionButtonCreatesWhenThereAreNoRegions() {
    XCTAssertEqual(
      makeModel(state: state(scope: .regions)).0.selectionButtonTitle, "Create Regions…")
    let regions = [FocusRegion(displayID: left, rect: rect)]
    XCTAssertEqual(
      makeModel(state: state(scope: .regions, regions: regions)).0.selectionButtonTitle,
      "Edit Regions…")
  }

  func testStatusTextExplainsWhyNothingIsBlurred() {
    let connected = [MenuBarDisplay(id: left, name: "Left")]
    var paused = FocusRegion(displayID: right, rect: rect)
    let disabled = FocusRegion(displayID: left, rect: rect, isEnabled: false)
    let cases: [(MenuBarState, String, Bool)] = [
      (state(isEnabled: false), "Off", false),
      (state(displays: connected, isEnabled: true), "On", true),
      (state(scope: .displays([]), isEnabled: true), "No display selected", false),
      (
        state(scope: .displays([right]), displays: connected, isEnabled: true),
        "Selected displays not connected", false
      ),
      (
        state(scope: .displays([left]), displays: connected, isEnabled: true),
        "On", true
      ),
      (
        state(scope: .regions, regions: [disabled], displays: connected, isEnabled: true),
        "No active region", false
      ),
      (
        state(scope: .regions, regions: [paused], displays: connected, isEnabled: true),
        "Regions paused: display not connected", false
      ),
    ]
    for (state, text, effective) in cases {
      let model = makeModel(state: state).0
      XCTAssertEqual(model.statusText, text)
      XCTAssertEqual(model.isEffective, effective, text)
    }
    paused.displayID = left
    let model = makeModel(
      state: state(scope: .regions, regions: [paused], displays: connected, isEnabled: true)
    ).0
    XCTAssertEqual(model.statusText, "On")
  }

  func testStatusTextReportsMissingFocusWindow() {
    var lost = state(isEnabled: true)
    lost.hasFocusWindow = false
    let model = makeModel(state: lost).0
    XCTAssertEqual(model.statusText, "No focused window detected")
    XCTAssertFalse(model.isEffective)

    var off = lost
    off.configuration.isEnabled = false
    XCTAssertEqual(makeModel(state: off).0.statusText, "Off")
  }

  func testPersistenceNoteExplainsWhyNothingIsSaved() {
    XCTAssertNil(makeModel().0.persistenceNote)
    let unreadable = makeModel(state: MenuBarState(persistenceIssue: .unreadable)).0
    XCTAssertEqual(
      unreadable.persistenceNote,
      "Saved settings could not be read. Changes are not saved."
    )
    let newer = makeModel(state: MenuBarState(persistenceIssue: .newerVersion)).0
    XCTAssertEqual(
      newer.persistenceNote,
      "Saved settings come from a newer version. Changes are not saved."
    )
  }

  func testSwitchingBackToDisplaysRestoresTheLastSelection() {
    let (model, controller, _) = makeModel(state: state(scope: .displays([left, right])))
    model.selectScope(.regions)
    model.selectScope(.displays)
    XCTAssertEqual(model.state.configuration.scope, .displays([left, right]))
    XCTAssertEqual(controller.calls, [.setScope(.regions), .setScope(.displays([left, right]))])
  }

  func testScopeSummaries() {
    let both = [MenuBarDisplay(id: left, name: "A"), MenuBarDisplay(id: right, name: "B")]
    XCTAssertEqual(makeModel(state: state()).0.scopeSummary, "All Displays")
    XCTAssertEqual(
      makeModel(state: state(scope: .displays([]), displays: both)).0.scopeSummary,
      "No display selected")
    XCTAssertEqual(
      makeModel(state: state(scope: .displays([left]), displays: both)).0.scopeSummary,
      "1 display")
    XCTAssertEqual(
      makeModel(state: state(scope: .displays([left, right]), displays: both)).0.scopeSummary,
      "2 displays")
    XCTAssertEqual(
      makeModel(state: state(scope: .displays([left, right]), displays: [both[0]])).0.scopeSummary,
      "2 displays, 1 paused")
    XCTAssertEqual(makeModel(state: state(scope: .regions)).0.scopeSummary, "No regions")
  }

  func testRegionSummaryCountsPausedAndDisabledRegions() {
    let regions = [
      FocusRegion(displayID: left, rect: rect),
      FocusRegion(displayID: left, rect: rect),
      FocusRegion(displayID: right, rect: rect),
      FocusRegion(displayID: left, rect: rect, isEnabled: false),
    ]
    let connected = [MenuBarDisplay(id: left, name: "A")]
    XCTAssertEqual(
      makeModel(state: state(scope: .regions, regions: regions, displays: connected)).0
        .scopeSummary,
      "4 regions, 1 paused, 1 disabled")
    XCTAssertEqual(
      makeModel(state: state(scope: .regions, regions: [regions[2]], displays: connected))
        .0.scopeSummary,
      "1 region, 1 paused")
  }

  // MARK: Exceptions

  func testExceptionsOfOneAppAreNumbered() {
    let refs = (1...3).map { WindowReference(windowID: $0, ownerPID: 1, generation: 1) }
    let exceptions = [
      MenuBarException(reference: refs[0], appName: "Safari"),
      MenuBarException(reference: refs[1], appName: "Notes"),
      MenuBarException(reference: refs[2], appName: "Safari"),
    ]
    let model = makeModel(state: MenuBarState(exceptions: exceptions)).0
    XCTAssertEqual(exceptions.map(model.name(of:)), ["Safari (1)", "Notes", "Safari (2)"])
  }

  func testExceptionDisplayNameUsesAppName() {
    let ref = WindowReference(windowID: 1, ownerPID: 1, generation: 1)
    XCTAssertEqual(MenuBarException(reference: ref, appName: "Notes").displayName, "Notes")
    XCTAssertEqual(
      MenuBarException(reference: ref, appName: " ").displayName, "Unknown window")
  }

  func testExceptionRemovalIsForwarded() {
    let exceptions = (0..<7).map {
      MenuBarException(reference: WindowReference(windowID: UInt32($0), ownerPID: 1, generation: 1))
    }
    let (model, controller, _) = makeModel(state: MenuBarState(exceptions: exceptions))
    model.removeException(exceptions[0])
    XCTAssertEqual(controller.calls, [.removeException(exceptions[0].reference)])
    XCTAssertEqual(model.state.exceptions.count, 6)
  }

  // MARK: Icon

  func testStatusIconsDifferInShapeAndLabel() {
    let icons = [StatusIcon.make(isEnabled: true), StatusIcon.make(isEnabled: false)]
    XCTAssertEqual(Set(icons.map(\.symbolName)).count, 2)
    XCTAssertEqual(Set(icons.map(\.accessibilityLabel)).count, 2)
  }

  func testViewModelIconFollowsTheSwitch() {
    let (model, _, _) = makeModel()
    XCTAssertEqual(model.statusIcon.kind, .off)
    model.setEnabled(true)
    XCTAssertEqual(model.statusIcon.kind, .active)
  }
}
