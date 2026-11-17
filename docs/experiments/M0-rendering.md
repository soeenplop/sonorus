# M0 – Rendering feasibility

As of 17 November 2026.
Prototypes: [`Experiments/Rendering/`](../../Experiments/Rendering/README.md).

This document strictly separates **verified** (programmatically checked or
measured, with `VERIFIED`/`OBSERVED` in the tool output) from **unverified**
(hypothesis or only judgeable by looking, `MANUAL`). The automated runs cannot
see the screen: **every statement about the blur impression, seams, corners or
flicker is unverified.**

## 1. Summary

- **Variant A (effect panel above everything + mask)** works mechanically:
  panels on both displays, click-through, non-activating, removed without
  leftovers. A mask via `maskImage`, however, costs **90–200 ms per update**
  and is therefore unsuitable for movement and focus changes. Effect **tiles**
  (one `NSVisualEffectView` per visible rectangle) cost **typically 2–12 ms**
  (median ≈ 5 ms, release).
- **Variant C (effect panel below the focused foreign window via
  `order(.below, relativeTo:)`)** works mechanically as well: an inactive
  accessory process can order its panel directly below a window of another
  app; this stays stable without outside changes (0 drifts in 32 checks).
  However, any foreign app that brings a window to the front lands **above**
  the panel and stays sharp until the next check. There is no public
  notification for z-order changes, so polling is required.
- **Hybrid C + A tiles** (ordering as in C, tiles only over visible parts of
  inactive windows *below* the panel) combines the strengths: the focused
  window including shadow, rounded corners and transparency lies above the
  effect in the z-order (verified; the visual impression is not), dragging or
  resizing the active window needs **no** mask update, the desktop and
  exceptions stay sharp. Tile update 10–15 ms.
- **Variant B** could not be run (no Screen Recording permission, deliberately
  not requested). The GPU part was measured offline: Gaussian blur + dimming
  costs ≈ 1.3 ms per frame and display at half resolution on an M4, almost
  independent of the radius.
- **Focus:** without Accessibility, `AXFocusedWindow` fails with
  `kAXErrorAPIDisabled` (−25211). The public AX → CG mapping only works via
  pid + frame (+ title, which needs Screen Recording) and is not unique. The
  AX path is implemented but **untested** on this system.
- **Recommendation:** hybrid C + A tiles as the primary candidate, A tiles as
  the fallback, B only if the native blur turns out not to be adjustable
  enough after manual review. Confidence: **medium** for the mechanics,
  **low** for visual suitability as long as section 10 has not been done.

## 2. Test environment and method

| Property | Value |
| --- | --- |
| System | macOS 27.0.1 (26A434), Apple M4, Xcode 27.2, Swift 6.4.2 |
| Display 1 (main) | DELL S3422DWG, 3440×1440 pt, scale 1×, Quartz (0, 0) |
| Display 2 | Built-in Retina, 1470×956 pt, scale 2× (2940×1912 px), Quartz (−1470, 0) |
| Accessibility (`AXIsProcessTrusted`) | **no** |
| Screen Recording (`CGPreflightScreenCaptureAccess`) | **no** |
| Reduce transparency / reduce motion | off / off |
| Window layout | about 24 normal windows of ≈ 17 apps on the main display |

The permissions were not requested because the request shows blocking system
dialogs. The second display configuration (1× next to 2×, negative x
coordinates) covers the plan's check point “different scales” geometrically.

Check methods without permissions:

- **Z-order and geometry:** `CGWindowListCopyWindowInfo` returns level,
  frame, pid and front-to-back order even without Screen Recording.
- **Click-through:** `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
  at a point of a blurred window. The control experiment
  `--no-click-through` returns the overlay number instead, so the method
  demonstrably distinguishes the cases.
- **Focus neutrality:** `NSWorkspace.frontmostApplication` and
  `NSApp.isActive` before and after showing the overlay.
- **Cleanup:** after every run CGWindowList must show none of the tool's
  windows. That was the case in all runs.
- **Timings:** `DispatchTime` around snapshot, mask/tile construction and
  `CATransaction.flush()`. Measured only until the commit to the
  WindowServer, not until the visible frame.

An automated focus scenario (`TestWindows --script`, started via
LaunchServices) activates a test app with three windows, switches the key
window within the app twice and then quits.

## 3. Window infrastructure (all variants)

Code: [`SpikeKit/Overlay.swift`](../../Experiments/Rendering/Sources/SpikeKit/Overlay.swift),
[`SpikeKit/Lifecycle.swift`](../../Experiments/Rendering/Sources/SpikeKit/Lifecycle.swift).

Configuration: `NSPanel` with `[.borderless, .nonactivatingPanel]`,
`canBecomeKey/Main = false`, `isOpaque = false`, clear background, no shadow,
`ignoresMouseEvents = true`, `hidesOnDeactivate = false`,
`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
.fullScreenAuxiliary]` and the app policy `.accessory`.

**Verified**

- One panel per `NSScreen` covers exactly the Quartz frame of the display,
  also on the 2× display with a negative origin. The AppKit ↔ Quartz
  conversion via the height of the primary display is correct.
- Click-through: the hit test at blurred points returns the foreign window.
  Without `ignoresMouseEvents` it returns the overlay (control).
- Level `normal + 1` (A, B): no normal foreign window lies above it. Level
  `normal` (C) orders itself between foreign windows.
- Removal without leftovers on timeout, signals and errors. A watchdog kills a
  hanging process.
- **Inherited activation (new finding):** an unbundled program started from
  the currently frontmost app (here the terminal) was activated on its first
  `orderFrontRegardless()` **despite `.accessory` and `.nonactivatingPanel`**
  (5 of 6 runs). With another app frontmost (Safari) this happened in 0 of
  8 runs. The tools detect this via `didBecomeActiveNotification` and hand the
  activation back immediately with `NSRunningApplication.activate()`.
  Afterwards the checks “frontmost unchanged” and “app not active” held in all
  runs.
- **Cooperative activation:** a process started from the shell whose parent
  is not frontmost cannot activate itself with `NSApp.activate()`. Its windows
  still came to the front with `makeKeyAndOrderFront`, without activation.

**Unverified / manual**

- Behaviour in full-screen Spaces, on Space changes, in Mission Control,
  Exposé, “Show Desktop” and Stage Manager. `.stationary` keeps the panel in
  place in Exposé; whether it covers system overviews there is open.
- Whether a click on a blurred window really activates it and whether
  scrolling and drag and drop arrive. The hit test is a strong indication,
  but not real event delivery.
- Whether a bundled `LSUIElement` app (the product) started via Finder or at
  login avoids the inherited activation. That is to be expected, but not
  checked.

## 4. Variant A – effect panel above all normal windows

Code: [`Sources/VariantA/main.swift`](../../Experiments/Rendering/Sources/VariantA/main.swift),
masks in [`SpikeKit/Overlay.swift`](../../Experiments/Rendering/Sources/SpikeKit/Overlay.swift)
(`MaskBuilder`) and [`SpikeKit/Tiles.swift`](../../Experiments/Rendering/Sources/SpikeKit/Tiles.swift).

**Approach:** per display a panel at level `normal + 1` with an
`NSVisualEffectView` (`.behindWindow`, `state = .active`, because the panel
never becomes key). Two mask strategies:

1. `--mask image`: one display-sized effect view with `maskImage`, painted
   back to front with the painter's algorithm. Inactive windows fill, the
   focused window and exceptions punch out, each with rounded corners. That
   yields exactly “visible parts of inactive windows”. Dimming is done by a
   `DimView` with the same mask.
2. `--mask tiles`: exact visible rectangles via rectangle subtraction. Each
   rectangle gets a pooled `NSVisualEffectView` plus a black dim layer; only
   frames are updated. This maps directly to `Contracts.DisplayEffectMask`
   (non-overlapping rectangles).

**Verified** (release, ≈ 24 normal windows, 11–12 inactive visible)

| Measurement | `image` | `tiles` |
| --- | --- | --- |
| Total update (n = 9 per run) | mean 122 ms, p50 112 ms, max 201 ms | mean 18.6 ms, p50 4.7 ms, max 85 ms¹ |
| of which effect mask/tiles | 46–66 ms | 0.1–2.8 ms |
| of which dim layer | 13–27 ms | included in tiles |
| of which `CATransaction.flush` | 30–50 ms (first time 166 ms) | 0–8.5 ms |
| Activation notification → mask committed | 123 ms | 7.6 ms |
| Tiles | – | 19–57 |

¹ The outlier was entirely `CGWindowListCopyWindowInfo` while an app was
quitting (closing animation). It also occurred in variant C (77–87 ms).

- A focus change via app activation is processed immediately via
  notification. A change of the key window within an app is only detected by
  polling (10 Hz), without AX.
- The activation notification arrives **before** the first window of the new
  app: the first snapshot yields “no focus”. Without a countermeasure,
  everything would briefly blur. Per PLAN 3.1, the effect should be removed
  temporarily or the previous state kept.
- Closing windows stay in the list during the animation with a falling
  `kCGWindowAlpha` (observed: 0.51 and 0.01). Windows with α < ≈ 0.05 must be
  ignored.
- `--layers N`, `--sweep` (14 materials, α 1/0.75/0.5/0.25) and `--full` run
  and clean up. This is only checked for function, not visually.

**Blur strength in A:** NSVisualEffectView has no public radius. Public
controls are:

- **Material:** every material brings a fixed, system-defined blur with a
  tint. The steps are discrete and depend on the appearance and the macOS
  version.
- **`alphaValue` of the effect view:** it cross-fades between the sharp and
  the blurred image. At intermediate values the sharp and the blurred image
  lie on top of each other; that is not a smaller radius. Whether this is
  acceptable as a “weaker blur” has to be judged **manually**.
- **Stacked panels (`--layers`):** whether an upper behind-window panel blurs
  the lower one again (stronger blur) is **unverified**.
- **Dimming** strengthens the impression but is not blur. Per PLAN 5 the
  slider must not silently be reduced to it.
- `CABackdropLayer` and private filter parameters are private and excluded.
  `NSGlassEffectView` (macOS 26+) exists publicly, was not evaluated and is
  Liquid Glass, not an adjustable blur.

**Risks A**

| Topic | Assessment |
| --- | --- |
| Masking/performance | `maskImage` too slow for movement; tiles fast but square |
| Rounded corners/shadow | Tiles are rectangular: in the transparent corners of the active window (≈ 10–20 pt) content behind it stays sharp, and the corners of inactive windows show slightly blurred desktop. The shadow of the active window lies **below** the effect and gets blurred. Check visually |
| Dragging the active window | Every movement requires tile updates. Without AX only via polling; with AX it depends on how often `kAXWindowMovedNotification` arrives while dragging (unverified). Visible trailing is expected |
| Foreign floating windows | Level ≥ 3 lies above the panel and stays sharp, even when inactive |
| Several displays/scale | Geometry verified; appearance at the display edge manual |
| Spaces/full screen | Collection behaviours set, effect manual |
| Reduce transparency | Expected: the material is drawn opaque and **hides** inactive windows completely. High risk, check manually; then dim only or B |
| Energy | WindowServer CPU in quiet phases 0–5 % with overlays (baseline 0–2 %), strongly overlaid by user activity (baseline peaks up to 46 %). No reliable energy measurement (`powermetrics` needs sudo) |
| Permission UI | none for rendering; focus needs Accessibility |

## 5. Variant C – effect panel relative below the focused window

Code: [`Sources/VariantC/main.swift`](../../Experiments/Rendering/Sources/VariantC/main.swift).

**Approach:** per display a panel at level `normal` with a display-filling
effect, plus `panel.order(.below, relativeTo: Int(focusedCGWindowID))`.
Everything below is blurred, the focused window stays sharp without a mask. A
drift check (4 Hz) compares the z-order with CGWindowList and reorders with
`--follow`.

**Verified**

- **The hypothesis holds mechanically:** a non-active accessory process
  orders its panels directly below a window of another app via its foreign
  CGWindowID (panels at z 3/4, target at z 2, the only normal foreign window
  above = target). On reordering the tool checks this again every time.
- Without outside changes the position is stable (12/12 and 32/32 checks
  without drift).
- Cost of `order(.below)` for both panels plus flush: 0.7–4.7 ms.
- Scenario: app activation, two key window changes within the app and the
  app quitting were followed correctly. After every step the panel lay
  directly below the right window again.
- **Limits:** changes within an app produce no NSWorkspace notification. They
  were only detected by the drift check (≤ 250 ms). Windows that a *non-active*
  app brings to the front (in the test: a shell-started app without
  activation) also land above the panel and are sharp until the drift repair.
- Click-through (the hit test returns the blurred foreign window).

**Unverified / manual**

- The blur impression and whether shadow, rounded corners and transparency of
  the active window lie perfectly sharp above the effect. That is the
  expected main advantage.
- Whether the panel visibly “jumps” during the activation animation (briefly
  sharp windows of the new app) and how long that lasts.
- Behaviour with full-screen windows, with sheets and dialogs (own window
  numbers: a dialog above the main window is sharp, the main window as well
  as long as it lies above the panel) and with Stage Manager.
- Whether system components or apps permanently force foreign windows
  “above” the panel, so that a race arises.

**Risks C**

| Topic | Assessment |
| --- | --- |
| Ordering relative to foreign windows | works, but every foreign reorder breaks it; there is no z-order notification, so polling (CGWindowList ≈ 0.4–0.6 ms) is mandatory |
| Inactive windows above the panel | visibly sharp until detected (poll interval) |
| Desktop/Dock area | A full-area panel also blurs and dims the desktop, contrary to PLAN 3.2 at the time; the remedy is the hybrid (section 6) |
| Exceptions, regions | need masks; not possible without a mask |
| Several displays | the z-order is global; two panels below the same window verified |
| Rounded corners/shadow/transparency | correct by construction (expected, manual) |
| Spaces/full screen | level `normal` with `.canJoinAllSpaces` in full-screen Spaces: manual |
| Energy | as A; no reliable difference measured |

## 6. Hybrid C + A tiles (`VariantC --mask tiles`)

**Approach:** ordering as in C. Instead of a full area, effect and dim tiles
only lie on the visible parts of inactive windows **below** the panel. The
focused window does not count as an occluder, because it lies above the
panel. Exceptions are left out.

**Verified**

- Same ordering results as C. Tile updates: mean 16 ms, p50 12 ms (first
  build 47 ms including view creation, otherwise 6–15 ms).
- The tile geometry does not depend on the position or size of the focused
  window (by construction: it is excluded from the computation). Dragging the
  active window therefore triggers no update.

**Consequence for the contracts:** the rules of PLAN 3.2 (“visible parts of
inactive windows”) treat the active window as an occluder. For the hybrid the
renderer instead needs **the window it orders below** and a mask **without
that window as an occluder**. `RenderScene` would need e.g. an
`orderBelow: WindowReference?` and suitably computed masks. That change
belongs in the shared contracts (DEVELOPMENT.md); the spike does not change
them.

**Risks:** as C (drift and polling), plus square tiles at the **inactive**
windows: a thin strip of desktop is blurred at their corners. Exceptions that
lie *above* the focused window are sharp anyway. Exceptions below are left
out and stay correctly covered, because the z-order stays unchanged
(PLAN 3.2).

## 7. Variant B – ScreenCaptureKit + GPU blur

Code: [`Sources/VariantB/main.swift`](../../Experiments/Rendering/Sources/VariantB/main.swift),
[`Sources/BlurBench/main.swift`](../../Experiments/Rendering/Sources/BlurBench/main.swift).

**Approach:** one `SCStream` per display with
`SCContentFilter(display:excludingApplications: [own app])` (against
feedback, additionally `sharingType = .none`), BGRA, `--downscale 0.5`, at
most 30 fps. Then Core Image `applyingGaussianBlur(sigma:)` and
`CIColorMatrix` for dimming. The result is drawn as a `CGImage` into a layer
overlay at level `normal + 1`, masked via a `CAShapeLayer` of tiles. Measured
are processing time, frame interval and latency `displayTime` → processed.

**Verified**

- Without permission B exits cleanly without a prompt (exit 2).
  Without Screen Recording `kCGWindowName` is only set for 6 of 35 windows,
  and only for the WindowServer's own windows.
- GPU cost (BlurBench, release, checkerboard, including waiting for the GPU
  to finish, mean of 30 runs):

| Display (pixels) | Downscale | r = 0 (dim only) | r = 4 pt | r = 16 pt | r = 32 pt |
| --- | --- | --- | --- | --- | --- |
| DELL 3440×1440 | 1 | 1.48 ms | 5.12 ms | 4.02 ms | 4.05 ms |
| DELL | 0.5 | 0.47 ms | 1.32 ms | 1.31 ms | 1.24 ms |
| DELL | 0.25 | 0.25 ms | 0.46 ms | 0.54 ms | 0.47 ms |
| Retina 2940×1912 | 1 | 0.49 ms | 4.68 ms | 4.56 ms | 4.76 ms |
| Retina | 0.5 | 0.45 ms | 1.51 ms | 1.33 ms | 1.41 ms |
| 5K 5120×2880 (synth.) | 1 | 0.97 ms | 10.76 ms | 10.20 ms | 10.41 ms |
| 5K | 0.5 | 0.82 ms | 3.63 ms | 2.95 ms | 3.27 ms |

  The radius has little influence, because Core Image computes internally via
  a pyramid. At 30 fps and half resolution on both displays this yields a GPU
  load of ≈ 8 %. Not included are the capture itself, the `createCGImage`
  readback (the prototype uses it for simplicity; production would need
  direct rendering into a Metal texture or IOSurface) and the compositing
  cost.

**Unverified:** the entire live path, image/mask offset while dragging
(ghosting), capture latency, the recording indicator in the menu bar and
Control Center, recurring permission dialogs on macOS 15+, protected content
(DRM, password fields) and energy in continuous operation.

**Risks B:** the permission including a visible recording indicator as a
product property. Image and geometry are always offset by at least one frame.
Add to that the energy demand of a continuous stream, protected content and
the complexity (Metal path, frame pacing, hotplug). Advantage: the radius is
freely and steplessly adjustable and independent of “Reduce transparency”.

## 8. Focus detection and mapping

Code: [`Sources/FocusProbe/main.swift`](../../Experiments/Rendering/Sources/FocusProbe/main.swift),
[`SpikeKit/Focus.swift`](../../Experiments/Rendering/Sources/SpikeKit/Focus.swift).

**Flow (public APIs only):**

1. `NSWorkspace.frontmostApplication` → pid.
2. `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` →
   `kAXPosition`/`kAXSize` (global top-left coordinates, the same space as
   CGWindowList), title, role, subrole, minimized and `AXFullScreen`.
3. Mapping to CGWindowList via the same pid, level 0 and frame ±2 pt. With
   several matches the title decides; on a tie the frontmost in the z-order
   wins (`uncertain`).
4. Without AX the heuristic “frontmost normal window of the frontmost app”
   applies, at most `uncertain`.
5. If the own process is frontmost, the previous target is kept
   (`FocusTracker`, PLAN 3.1).

`_AXUIElementGetWindow` (AX element → CGWindowID) is **private** and not
used.

**Verified**

- Without Accessibility: `AXFocusedWindow` → `AXError −25211`
  (`kAXErrorAPIDisabled`). The call costs 0.013 ms; no dialog appears.
- Cost: CGWindowList snapshot mean 0.35–0.62 ms (p95 up to 3 ms, single
  outliers up to 85 ms while apps quit), query “above window X” 0.22 ms.
  Complete resolve 0.4 ms.
- Without Screen Recording `kCGWindowName` is empty for foreign windows. A
  title match AX ↔ CG therefore needs **both** permissions.
  `kCGWindowSharingState` reported 0 for 29 of 35 windows and is not
  meaningful without the permission.
- `didActivateApplication` arrives before the new window is at the front in
  CGWindowList. Key window changes within an app produce no workspace
  notification.

**Unverified** (needs Accessibility for the launching terminal): hit rate of
the frame mapping; ambiguity with tabs, identical frames and identical titles
(`TestWindows --same-title`); delivery and rate of `kAXFocusedWindowChanged`,
`kAXMainWindowChanged`, `kAXWindowMoved` and `kAXWindowResized` while
dragging; Electron apps; sheets and dialogs (subrole); full screen.

**Risks:** two equally sized windows of the same app at the same position
(tabs, stacked windows) can only be told apart by title or z-order without a
private API; that yields `uncertain`. For C a wrong mapping is immediately
visible, because the wrong window becomes sharp. The policy “remove the
effect when uncertain” is therefore important.

## 9. Recommendation

1. **Primary candidate: hybrid C + A tiles.** Reason: the active window stays
   sharp without a mask, with shadow and corners, and dragging or resizing
   the active window needs no updates. Masks (tiles) only change on focus or
   window list changes; that costs 10–15 ms. The desktop and exceptions stay
   correct. Price: permanent z-order polling (≈ 4–10 Hz, ≈ 0.5 ms each)
   against foreign windows that move on top.
2. **Fallback: A tiles** (level `normal + 1`). Robust against foreign
   reordering, but dragging the active window drags the mask after it.
   Without AX, seams and trailing are to be expected.
3. **Reject `maskImage` masks** (90–200 ms per update).
4. **B only** if the manual review shows that material/alpha do not meet the
   requirement “adjustable blur” (PLAN 2), or if “Reduce transparency” makes
   the native path unusable. The GPU cost is uncritical; the open risks are
   the permission indicator, offset and energy.

**Confidence:** medium for the mechanics (z-order, click-through, focus
neutrality, cleanup and timings are measured). **Low** for visual
suitability: nobody has seen the blur impression, controllability, corners
and flicker. The decision between the native path and B depends on the
checklist below.

## 10. Manual checklist for the person at the Mac

Preparation: `cd Experiments/Rendering && make build && make testapp`. For
the focus points, allow **Accessibility** for the launching terminal under
System Settings → Privacy & Security (then restart the terminal). Grant
Screen Recording only for B. Start the tools from a terminal and then click
into another window.

**Blur quality and controllability (decisive for A/C vs. B)**

1. `swift run VariantA --full --duration 10`: does the default material
   (`hudWindow`) read as blur or rather as a milky tint? Is text behind it
   still legible? Repeat with `--dim 0`.
2. `swift run VariantA --full --sweep --step 2 --duration 40 --dim 0`: for
   each `sweep n/17` line, note which materials show usable blur and how
   α 0.75/0.5/0.25 looks (less blur or a double image?).
3. `swift run VariantA --full --layers 2 --dim 0` and `--layers 3`: does the
   blur get stronger?
4. Switch between light and dark mode and repeat 1–2.
5. Turn on System Settings → Accessibility → Display → **Reduce
   transparency** and repeat 1: do inactive windows become invisible
   (opaque)? Turn it off again afterwards.
6. Decide: is the discrete, native controllability enough (PLAN 2)?

**Masks, corners, shadows (A and hybrid)**

7. `swift run VariantA --mask tiles --follow --duration 30`: does the active
   window stay sharp? What do its corners and shadow look like? Are edges
   between tiles visible?
8. Like 7, but `--mask image`: difference at the corners, noticeable delay on
   focus changes?
9. `swift run VariantC --mask tiles --follow --duration 30`: corners, shadow
   and transparency of the active window perfect? Desktop sharp?
10. In 7 and 9, drag and resize the active window: trailing, or sharp or
    blurred seams? (Nothing should trail in the hybrid.)

**Focus and interaction**

11. In 7 and 9, click a blurred window: does it become active and sharp? Does
    the click arrive? Test scrolling in a blurred window and drag and drop.
12. `⌘Tab`, ⌘+backtick (windows of the same app), closing a window,
    minimizing, quitting an app: how long does the wrong state stay visible?
13. `swift run TestWindows --count 3 --same-title --panel --duration 60`
    alongside 9: utility panel, identical titles, dialog (`⌘W` in an app with
    unsaved changes), context menu, popover.
14. With Accessibility: `swift run FocusProbe --watch 30`, switching by
    click, `⌘Tab` and ⌘+backtick and dragging a window. Note: is
    `confirmed`/`uncertain` right? Do `AXWindowMoved` events arrive while
    dragging or only at the end?

**System and several displays**

15. Drag a window across the edge between the 1× and the 2× display (7 and
    9): is the effect right on both sides?
16. Full-screen app, Space change, Mission Control, Exposé, “Show Desktop” and
    Stage Manager during 7 and 9: do the effects stay correct, disappear, or
    cover system overviews?
17. `Ctrl-C` during a run: do all overlays disappear immediately?

**Variant B (only if needed)**

18. `swift run VariantB --request`, grant the permission, restart the
    terminal, then `swift run VariantB --radius 12 --duration 20`: note
    stepless blur (`--radius 4/24`), offset while dragging, the recording
    indicator in the menu bar and the measurements at the end.

## 11. Open points for R0

- Contract extension for the hybrid (`orderBelow` and a mask basis without
  the focused window as an occluder), see section 6.
- Focus policy for the time window “app activated, but no window at the front
  yet” and for closing windows (α filter).
- Whether a bundled `LSUIElement` app avoids the inherited activation.
  Independently of that, Sonorus must detect its own activation and must not
  take itself as the target.
- Measure energy with `powermetrics` or Instruments (needs administrator
  rights).

## 12. Sources (Apple documentation)

The URLs were checked for existence (HTTP 200). The statements above come
from our own measurements; where they describe API behaviour without being
measured, they are marked as unverified.

- NSVisualEffectView: https://developer.apple.com/documentation/appkit/nsvisualeffectview
- maskImage: https://developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage
- state: https://developer.apple.com/documentation/appkit/nsvisualeffectview/state-swift.property
- Material: https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum
- Behind-window blending: https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow
- NSGlassEffectView: https://developer.apple.com/documentation/appkit/nsglasseffectview
- NSWindow.order(_:relativeTo:): https://developer.apple.com/documentation/appkit/nswindow/order(_:relativeto:)
- ignoresMouseEvents: https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
- nonactivatingPanel: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
- windowNumber(at:belowWindowWithWindowNumber:): https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)
- sharingType: https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.property
- Collection behavior: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct, canJoinAllSpaces: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces, stationary: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary, fullScreenAuxiliary: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary
- ActivationPolicy.accessory: https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory
- NSApplication.activate(): https://developer.apple.com/documentation/appkit/nsapplication/activate()
- yieldActivation(to:): https://developer.apple.com/documentation/appkit/nsapplication/yieldactivation(to:)
- accessibilityDisplayShouldReduceTransparency: https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency
- CGWindowListCopyWindowInfo: https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
- kCGWindowName: https://developer.apple.com/documentation/coregraphics/kcgwindowname
- CGPreflightScreenCaptureAccess: https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()
- CGRequestScreenCaptureAccess: https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()
- AXIsProcessTrusted: https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
- AXUIElement.h (incl. kAXFocusedWindowAttribute): https://developer.apple.com/documentation/applicationservices/axuielement_h
- AX notifications: https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h
- SCContentFilter: https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- SCStream: https://developer.apple.com/documentation/screencapturekit/scstream
- CIImage.applyingGaussianBlur(sigma:): https://developer.apple.com/documentation/coreimage/ciimage/applyinggaussianblur(sigma:)

## Continuation: full area and pending manual review

**Status:** the earlier A activation latencies are invalid: they measured the
end of the first update, not the takeover of the activated window. The
previous visual statements remain unproven. The decision native versus
capture stays open until T1 and T2. `VariantC --mask full` uses one
contiguous native effect area including the wallpaper; protected windows lie
above it or are left out in the overlay fallback. The menu bar is left out
spatially, the Dock and higher system windows stay above the panel. Other
normal windows are not left out wholesale. The behaviour of unusual window
levels and of native masking is open manually.

Run all of the following commands in `Experiments/Rendering`; they open
visible overlays and were not run in this continuation:

- **T1 controllability:** `swift run VariantA --full --sweep --step 2 --duration 40 --dim 0`, then `swift run VariantA --full --layers 2 --dim 0` and `swift run VariantA --full --layers 3 --dim 0`. Compare material, alpha and additional layers regarding perceived blur and double images.
- **T2 reduce transparency:** turn the system setting on, run `swift run VariantC --mask full --follow --duration 30`, judge visibility and opacity; reset the setting afterwards.
- **T3 movement, sheets and Spaces:** `swift run VariantC --mask full --follow --duration 60` and for comparison `swift run VariantA --mask tiles --follow --duration 60`. Move windows across the whole area, open and close a sheet, switch Spaces; watch for stutter, trailing, ordering and wallpaper. Additionally check `swift run VariantC --mask layer --follow --duration 60` for mask alignment and blur.
- **T4 input:** during T3, click, scroll and drag in blurred windows; check that all events arrive.
- **T5 overlap and displays:** during T3, check overlapping windows, a foreign window in front of the focus, the Dock and the menu bar; drag windows across display edges and negative coordinates. With `--mask tiles` specifically check for visible tile seams.

Headless tests only check ordering and mask geometry against synthetic window
lists. They confirm neither actual WindowServer compositing nor appearance,
input or Space behaviour.

## Integration fixes after review

Five reproducible bugs were fixed before the integration:

- Every part of the protected group must lie in front of **every** effect
  window; a group window between two display panels fails the check.
- An unresolvable focus of a foreign application hides the effects. Only
  explicit own user interface may keep the previous target.
- A failed relative ordering is cached until the anchor changes or a Space
  reset, instead of flickering again on every query.
- Visible non-normal surfaces are taken into account in the masks, including
  negative levels. Desktop and icon levels are kept separate and stay in the
  effect. Inactive windows in front close holes again, so that a system
  surface creates no cut-out through them.
- Variant A filters invisible or nearly transparent windows uniformly before
  the signature, image mask and tile computation.

Eight headless tests pass, including regressions for these states. That is no
proof of the actual WindowServer ordering or the blur appearance: T1–T5 remain
manual acceptance work. No live overlays were started for this integration.
Rectangle geometry and publicly available window information still limit the
accuracy.

## Multi-display fix and soft menu edge (17 November 2026)

**New manual feedback:** `VariantA --full --sweep --dim 0` produces blur on
both displays. According to the user the initial material (`hudWindow`) is
acceptable; a later state looks too strong. Without a sweep log it is unknown
which later material/alpha state was meant (the sweep first repeats
`hudWindow`). `hudWindow` stays the default. This is no acceptance of the
alpha control or of “Reduce transparency”.

In C, anchor placement, verification, failure cache and visibility were
coupled for all panels. A global z-order check could detect neither a moved
panel frame nor a wrong display assignment. The feedback on A points rather
to a C-specific placement bug than to missing display enumeration. **Not
proven** is whether relative ordering against a foreign anchor actually moves
the panel to another display or Space; there was no live run for this fix.

C now plans and checks per display:

- Only a locally intersecting anchor is used relatively. Displays without a
  local anchor immediately get an overlay with cut-outs for the focus group.
- The AppKit display ID, the visible WindowServer entry, alpha, the expected
  Quartz frame and the relevant local z-order must match. Own panels do not
  count as foreign occluders. All locally intersecting parts of the focus
  group must lie in front of an anchored panel.
- The target frame is set before and after the relative ordering. If the
  check fails, only this display switches to the overlay; its cache is kept
  until the anchor changes or a Space reset. A still unconfirmed panel stays
  invisible, the others stay active independently.
- Overlay masks protect the group across display edges as well; rectangular
  cut-outs in the fallback avoid blur at protected corners. That can leave a
  sharp seam around rounded windows. In the fallback the geometry follows the
  polling; the public API offers no atomic coupling to foreign windows.
  Anchored full areas are not reordered on mere focus movement without a mask
  change.
- Space changes require two successful checks per panel. Public on-screen,
  frame and z-order data do not prove actual compositing visibility in the
  respective Space. Separate Spaces, full screen and Stage Manager remain to
  be checked manually; no private Space API is used. A display ID that no
  longer matches is hidden instead of reinterpreted; restart the spike after
  hotplug or arrangement changes.

`--menu-fade 24` (default, points) fades from clear to the configured
blur/dim strength directly below the menu bar edge. `--menu-fade 0` restores
the hard edge. It is an **alpha gradient for the perceived effect strength,
not a changing native blur radius**. Geometry mask and gradient are nested and
multiplied, also with `--mask-on host`; blur and dim use the same envelope. A
contiguous surface creates no additional stripes or tiles. With a hidden menu
bar (`menuBarInset == 0`) there is no artificial gradient, in particular none
at the bottom edge. The menu bar is left out, the Dock stays on its higher
level. `layer` and `tiles` leave out the menu area as well; tiles keep their
previous native seam risks.

**Verified headless:** the original eight tests plus four new tests with
several scenarios check two/three displays, primary/secondary focus, focus
spanning displays, negative coordinates, missing/moved panels, ID mismatches,
independent failure caches, local ordering and safe fallback masks. Gradient
tests check points, direction, limits, zero/clamp behaviour and the nested
mask structure for `effect` and `host` (with synthetic 2× geometry). This
proves no rendered native blur.

**User retest** (opens windows; not run here):

```sh
cd Experiments/Rendering
swift run VariantC --mask full --follow --material hudWindow --menu-fade 24 --poll 0.1 --duration 90
```

1. Check wallpaper and inactive windows on every display; move the focus
   first on the primary, then on the secondary, then across the edge, and
   resize it. The focus including sheets must stay sharp on every intersected
   area.
2. Compare the logs per `displayID`: `expected` and `actual` must match,
   `runtimeDisplayID` must fit the target, and `z`, `anchor`, `group` and
   `placement` must explain the respective anchor or overlay case. A local
   fallback must not turn off the other display. All displays are logged
   initially and after 0.4 seconds, then on reordering.
3. Judge the gradient directly below the menu text: blur and dim should start
   softly together, without stripes or seams. Dock and menu text sharp?
   Compare with `--menu-fade 0`, then `--mask-on host` and `--dim 0`.
4. Check 1×/2×, negative display positions and an automatically hidden menu
   bar; no unwanted gradient may appear at the bottom. Switch Spaces one by
   one, test full screen/Stage Manager and input through the overlay.
5. T1/T2 (alpha control and “Reduce transparency”) remain pending. No
   additional permission or recording is needed for this retest; existing
   Accessibility must be available for reliable focus.

### Retest: placement confirmed, image still wrong

The user still reports only one blurred display and sharp desktop widgets.
The submitted log shows macOS 27.0.1, a 1× DELL display (ID 2, primary) and
the 2× Retina display (ID 1, negative x coordinate). For **both** panels the
target and actual frames and the runtime display ID match, initially and
after 0.4 seconds. The DELL lies below the focus anchor, the Retina uses the
overlay fallback. 417 checks report no further drift. That refutes a
permanently misplaced panel frame in this run; it still proves no native blur
visibility. AX and Screen Recording were not granted; the focus was
determined heuristically.

The full area therefore now uses the public `NSVisualEffectView.maskImage`
path by default instead of a nested mask on the effect's backing layer.
Geometry and menu gradient are composed into **one** alpha image per display
at its backing scale; dim uses the same image data. The independent placement
check stays. `--mask-backend layer` allows a direct comparison with the
previous path. An explicit `--mask-on effect` or `--mask-on host` also selects
the layer path, as long as `--mask-backend native` is not set explicitly.
This change is an alternative public compositing implementation, no proof of
a macOS bug. Raster masks can be more expensive to update than layer paths
(earlier measurements in section 5); their real latency has to be judged
again.

Negatively layered windows with the public process bundle ID
`com.apple.notificationcenterui` are treated as desktop widgets and no longer
punched out as a system surface to keep sharp. The restriction to negative
levels still protects raised Notification Center windows and banners. Unknown
processes stay protected; the detection of other widget hosts is not proven
without their window data. C now also queries desktop elements and logs their
owner, bundle ID, level and frame (no titles) at start. This makes the
mapping checkable in the user run.

Additional `mask displayID=... backend=... pieces=... centerEffect=...` lines
show whether the mask allows any effect at the display centre at all;
`sharp-surface` names the locally considered non-normal surfaces. That
separates unintended cut-outs from the compositing that still has to be
checked visually. `contentHidden` extends the placement logs.

14 headless tests pass, including new real alpha pixel checks at 1×/2× for
native masks (upper gradient, lower full strength, hard edge, geometry
cut-out), as well as widget, banner and system surface regression cases. No
live windows, recordings or permission prompts were started.

Next user run:

```sh
cd Experiments/Rendering
swift run VariantC --mask full --mask-backend native --follow --material hudWindow --menu-fade 24 --poll 0.1 --duration 90
```

Check wallpaper, inactive windows and desktop widgets on both displays; the
focus and sheets must stay sharp. For a direct comparison run the same
command with `--mask-backend layer`. If the bug persists, please record the
`surface`, `mask`, `sharp-surface` and `displayID` lines and the name of the
affected display. Multi-display effect, widget detection, gradient, mask
latency and Spaces remain visually open until this retest.

### Menu bar edge: light seam in the user's screenshot

The user explicitly names the light stripe below the menu bar as disturbing;
material and blur strength are not changed for it. The previous alpha
gradient started below the left-out menu bar and showed partly unblurred,
light window tops there. That is a cause hypothesis matching the screenshot,
not a measured proof of the compositing behaviour.

In full-area mode the panel now extends over the whole screen below the
higher system windows. The gradient ends inside the menu bar strip instead of
creating an additional transparent strip below it. `--menu-fade` is clamped
to the available menu bar height; with an automatically hidden menu bar there
is no artificial gradient. The system menu bar stays protected by its level
and the system surface masking. Native and layer masks use the same edge
computation.

15 headless tests pass. New real alpha pixel checks at 1× and 2× and with
24/33 points of menu bar height confirm that the very first content row lies
fully in the effect, even with an oversized requested gradient length. The
actual disappearance of the light seam remains to be confirmed visually:

```sh
swift run VariantC --mask full --mask-backend native --follow --material hudWindow --menu-fade 24 --poll 0.1 --duration 90
```

### Follow-up fix: flicker and a too large upper cut-out on the left

The user still reports flicker and a clearly larger gap at the top when a
window on the left display is active. The following concrete code paths were
fixed, without deriving a visual solution from that yet:

- Mere mask changes no longer hide the panel. Hide/verify stays required for
  actual level or anchor changes. Before, even an unchanged, correctly placed
  panel caused a brief hide.
- Full-area masks and their change detection are clipped per display.
  Changes exclusively on another display no longer cause an unnecessary
  rasterization of the local mask.
- System windows above level 1 lie above both panel placements anyway. Their
  partly large frames therefore no longer create cut-outs in the image below.
  System surfaces at level 1 or below stay protected, desktop widgets are
  still handled separately.
- A larger window of the same app behind the focus is no longer added to the
  sharp group as a parent window based on geometric containment alone. That
  could unintentionally protect normal document windows. Without real mapping
  data, a heuristically focused sheet can therefore not reliably protect its
  parent content as well; that remains a limit of the spike without
  Accessibility mapping.

18 headless tests check, among other things, large menu system frames,
nested windows of the same app and unchanged local masks for remote window
changes. The existing pixel, multi-display and occlusion tests remain. Native
compositing latency, actually flicker-free movement and the disappearance of
the upper gap must be confirmed in the desktop retest; no live overlay was
started automatically for that. The previous VariantC command stays valid.

### Full-area rule after a screenshot with staircase gaps

The new user screenshot shows many sharp, staircase-shaped stripes at the top
edge of the right display. The full-area mask still had wholesale cut-outs for
helper windows below or at level 1. That rule is too generous for “everything
except protected windows” and is replaced in the full-area spike: only the
focus group (in the overlay fallback) and explicit window exceptions create
cut-outs. Normal inactive windows in front still cover these exceptions
correctly. Wallpaper, desktop widgets and other background or helper surfaces
that are not explicitly excepted stay in the effect. Higher system windows
stay physically above the panels.

This is a targeted change of the full-area spike. The conservative production
rules and the experimental modes `tiles`/`layer` are not unified with it yet;
that must be integrated explicitly before the production renderer. The cause
of individual real system surfaces is not confirmed without a window snapshot
of the user session. A read-only WindowDump in a sandbox without desktop
access returned no displays or windows, so no statement about the user's
desktop was derived from it.

19 headless tests pass. A new two-display case with mixed scales and
staircase-arranged level 1/−1 helper windows checks: on the display without
focus and without exceptions there is no cut-out; in the anchored case the
real focus physically protects the local area; in the fallback exactly the
focus cut-out remains. The real pixel/compositor effect remains visually
open.

The diagnostics now log `protected-hole displayID=... rect=...` for parts
that are really punched out, instead of misleadingly calling non-normal
windows sharp. On a foreign display without focus overlap and without
exceptions there must be no `protected-hole` line. The same VariantC command
can be used for the retest; no additional approvals were requested
automatically.

### Focus transition and neutral menu bar (17 November 2026)

Current user finding: a light horizontal seam even with the previous gradient
**inside** the menu area, plus flicker on focus changes. The attached crop
shows a light upper band structure behind the sharp menu characters. It does
not prove which part comes from the system material, the wallpaper or the
alpha envelope. Moving the edge again would therefore be no proven solution.

`VariantC --mask full` now uses `--menu-fade 0` by default: the native alpha
mask is fully opaque behind the higher system menu bar up to the top screen
edge (except explicitly protected windows). No additional gradient, stripe,
colour or offset is introduced into the system compositing. `hudWindow`,
effect alpha and dim stay unchanged. Menu text and symbols are neither
rendered nor captured by us; they still lie on the higher system level.
`--menu-fade 12` or `24` remains a real explicit soft-fade option inside the
menu area, for native and layer masks. This option can make the reported seam
visible again; `0` is the default and the comparison baseline. The cause and
the visual neutrality of the native material remain open until the retest.

`--transition 0.18` is the new default in full-area mode. `0` switches
instantly, finite values are clamped to `0...0.6` seconds; NaN/±∞ and
unparsable values use `0.18`. `tiles`/`layer` keep their previous instant
behaviour; `--mask full --mask-backend layer` supports the transition with a
layer base mask and native local transition masks.

Architecture (`FocusTransition.swift`):

- Per display a pure planner holds the current target effect area and
  pairwise disjoint outgoing partial areas. Anchored panels also leave out the
  new focus group explicitly before their order is changed. Local anchors and
  remote overlays with the same frame, display and order verification remain.
  No arbitrary window levels create new holes.
- The unchanged background lies completely on the static base effect area.
  Only the previously protected, now visible area fades into the same blur
  with a monotonic smoothstep. Base and local effect areas do not overlap
  geometrically: neither a global clear/blur cross-fade nor two full-area
  blurs on top of each other. No blur radius is changed.
- Local `NSVisualEffectView`s lie in the **same panel**, have clipped native
  masks and the same `hudWindow`/dim configuration. Their view opacity is
  updated at most at 30 Hz. Masks are only rasterized on target changes and
  completion, never display-filling per animation frame. The duration starts
  after the mask preparation, so that its CPU cost does not use up the visible
  transition before its first frame. The menu gradient is kept in global
  coordinates while clipping.
- A quick change A→B→C cancels the old timer, takes over the current computed
  alpha distribution, clips it to the latest target and starts from there. C
  is protected immediately, the unchanged background stays stable.
  Generations and timers are independent per display. At most 16 local
  partial areas and about two display areas of local raster masks in total
  are allowed. On overload the oldest fragments finish immediately; the
  latest focus stays protected. Core Graphics path operations have numeric
  rounding residue in the subpixel range.
- An already visible, correctly framed full-area panel is not hidden on an
  anchor or level change. New masks are committed and flushed before the
  ordering. Unchanged verified panels are neither reordered nor re-masked.
  Frame/display errors, unverifiable placement, unknown focus and Space
  changes may still hide safely. Focus loss, Space changes and teardown stop
  all affected transitions.
- `transition displayID=... generation=... start/cancel/end` logs lifecycles
  without titles or frame spam. Safety aborts name the reason.

**Verified headless:** 24 tests (all previous 19 plus five new ones) check
clamp/instant mode, monotonic progression, immediate focus protection,
unchanged background alpha, freedom from overlap, A→B→C with takeover of the
running alpha, independent planners, cancel and allocation limits. Real 1×/2×
alpha pixels check continuous coverage over the whole menu area and every row
below the edge, as well as the kept explicit soft-fade option and identical
envelopes of clipped masks. These checks prove neither WindowServer
presentation atomicity nor the native blur/tint effect.

Recommended user retest (**not run** here):

```sh
cd Experiments/Rendering
swift run VariantC --mask full --mask-backend native --follow --material hudWindow --transition 0.18 --menu-fade 0 --poll 0.1 --duration 90
```

Switch A→B→C several times on both displays, also within an app, and check
overlapping windows and focus across the display edge. The new focus must be
sharp immediately; only the previously sharp visible area should blend softly
into blur, without global brightening or stronger blur. Judge the menu seam at
`--menu-fade 0`, then compare explicitly with `--menu-fade 12`.
`--transition 0` is the instant comparison version. Space changes may hide
safely, but must then come back correctly per display.

**Visually pending:** actual seamlessness of adjacent native views, mask
latency (rasterization can delay the first frame), the look of the opacity
cross-fade, no blur amplification by system-internal compositing, menu halo,
WindowServer ordering during app activation, Spaces and full screen. Public
APIs do not couple masks and foreign windows atomically; focus resolution
still follows notifications/polling. Rectangular focus masks can leave a sharp
seam at rounded corners. No live overlays, desktop recordings or permission
dialogs were started for this work. Only the user retest can provide a visual
acceptance.

Integration check: in the alternative layer backend the base mask is attached
to the effect/dim layers, even when the host mask mode is requested. A parent
host mask would clip the additionally inserted transition areas. A headless
view test checks their construction, masking and teardown. After this fix,
25 experiment tests as well as root lint/tests/build and experiment
lint/build pass. No live overlays were started; visual acceptance of the
transitions and the menu bar remains open.

### Fix: physical focus protection and logical transitions

The previous full-area transition mask with a permanent rectangular focus
hole is replaced. After verified local anchoring, the effect area also lies
completely below the focus group: the WindowServer protects its actual
contour including rounding, shadow and transparency. Only this physically
overlying group drops out of the real cut-outs; visible exceptions below the
panel stay left out, with rectangular refilling by inactive windows in front.

Before a reorder, a temporary rounded protection mask is installed
synchronously (including protection against overlapping transition
fragments). Only the verified display identity, geometry and local order
remove this guard. Missing or stale anchors still lead independently per
display immediately to the overlay fallback; if its verification fails, the
local area stays hidden. The host mask fix (`maskOnHost: false` on the
transition base) stays.

Logical overlay geometry serves separately to determine the outgoing visible
focus region on a real change of the focused window ID. It still fades in
over 180 ms. Movement of the same anchored window does not change the
rendered mask and creates no outgoing regions. Overlay geometry changes
happen immediately and end old fragments; quick focus changes take over the
current alpha state and end without leftover holes. The material strength
`hudWindow` and `--menu-fade 0` stay unchanged.

Overlay and the temporary guard cannot know exact individual app contours
from the public window list: `--corner-radius 12` is an approximation there
(optionally adjustable). Global window paths are rounded first and then
clipped to the display; display edges create no new rounded corners. Refill
pieces are not rounded.

Diagnostics without titles: `protection displayID=... mode=physical-anchor`,
`transient-guard` or `fallback-holes` is only printed on relevant mask or
placement changes. The earlier `protected-hole` logs per focus movement are
gone.

Unchanged manual retest (**not run** here):

```sh
cd Experiments/Rendering
swift run VariantC --mask full --mask-backend native --follow --material hudWindow --transition 0.18 --menu-fade 0 --poll 0.1 --duration 90
```

Optionally add `--corner-radius 12`. Drag the same focused window, switch
quickly between A/B/C, cover exceptions and move windows across display
edges. Checked automatically: synthetic geometry, anchor loss, guard
lifecycle, transition planning and mask pixels at 1×/2×. Visual desktop
quality, native foreign window ordering and shadow/transparency remain to be
checked manually; no success on the user's desktop is claimed.

Integration check: explicit outgoing focus areas are cleaned of transition
fragments that are already running. On quick changes between overlapping
windows their momentary opacity is kept instead of laying a second blur
fragment on top. A new regression test checks the overlap area and the kept
opacity. Afterwards 34 experiment tests pass in total; root lint/tests/build
and experiment lint/build pass as well. The visible contour and movement
remain open in the user retest.

### Retest: vector masks instead of `maskImage` on window changes

With `--mask-backend native` the previously active window briefly flashed
blurred at the start of every change. Window order takes effect immediately
in the WindowServer, a new `maskImage` only after the next compositing; in
addition every mask cost 50–80 ms of CPU rasterization. Countermeasures: a
protection mask keeps the old and the new focused window sharp, reordering
only after about 34 ms (`--guard-settle`), the overlay fallback is deferred
for up to 250 ms after focus changes, and transition fragments use
`CAShapeLayer` paths in the layer path as well.

User finding (17 Nov 2026): `--mask-backend layer` “clearly better”, only two
non-reproducible flicker events left; `native` keeps flickering. Measured in
the user run: mask update layer 4–6 ms (p95 8 ms) versus native about
32–55 ms; activation until verified ordering with layer 119–137 ms on
average. `layer` is therefore the default; `native` stays for comparison.
Open: residual flicker and the explicit confirmation that layer masks blur on
both displays including the background and widgets.

### M0 decision: variant D (backdrop cross-blur without masks)

`swift run VariantD --radius 24 --dim 0.3` (default transition 750 ms). Per
display two display-sized panels with `CABackdropLayer` (`gaussianBlur`,
`windowServerAware`) and a dim layer. The active panel lies directly below
the focused window. On a change the second panel is ordered below the new
focused window; both radii run in opposite directions as a render server
keyframe animation (`R·√p`, `R·√(1−p)`), the dims so that
`(1−a_in)(1−a_out) = 1−dim`. Everything behind both panels stays constant;
the old focused window and windows raised via ⌘Tab blur in from 0.
`CrossBlurTests` prove the constancy numerically.

User finding (17 Nov 2026): “awesome” – soft blurring out without corners,
edges or jumps. Previous approaches and why they were rejected:
`NSVisualEffectView` opacity (no real blur control), WindowServer window
radius (only rectangles, no partial transitions), mask/tile transitions
(flicker, square or white edges). Open: masks for regions and exceptions on
the backdrop layer visually, “Reduce transparency”, Spaces/full screen,
energy, `disablesOccludedBackdropBlurs` (off by default).
