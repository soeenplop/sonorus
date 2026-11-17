import AppKit
import SpikeKit

// Prints environment, displays and the on-screen window list (front to back).
// No windows, no prompts. Titles appear only with Screen Recording permission.
let args = Args()
CGWin.showTitles = args.flag("titles")
SpikeEnvironment.report()

let windows = WindowList.onScreen(includeDesktop: args.flag("desktop"))
Log.observed("\(windows.count) on-screen windows (front to back)")
for (index, window) in windows.enumerated() {
  print(String(format: "  %3d ", index) + window.shortDescription)
}

let named = windows.filter { $0.name != nil }.count
Log.observed("windows with kCGWindowName populated: \(named)/\(windows.count)")
let sharing = Dictionary(grouping: windows, by: \.sharingState).mapValues(\.count)
Log.observed("kCGWindowSharingState histogram: \(sharing)")

let calls = args.int("bench", default: 200)
let onScreen = Samples.measure(calls) { _ = WindowList.onScreen() }
Log.observed("CGWindowListCopyWindowInfo(onScreenOnly) cost: \(onScreen.summary)")
if let first = windows.first(where: \.isNormalLevel) {
  let above = Samples.measure(calls) { _ = WindowList.above(first.id) }
  Log.observed("CGWindowListCopyWindowInfo(onScreenAboveWindow) cost: \(above.summary)")
}
