# Sonorus – Plan

As of 17 November 2026.

## 1. Goal

Sonorus is a native macOS menu bar app that helps you focus on the active
window. Visible parts of inactive windows and the desktop background are
blurred and dimmed; the active window stays sharp. The app needs no
permissions.

## 2. Requirements

- Treat inactive windows and the desktop background within the chosen scope;
  the Dock and the menu bar stay sharp.
- Three scopes: all displays, selected displays, or freely drawn regions.
- Several regions, also on the same display and spread across displays.
- Mark windows as exceptions: they stay sharp even when inactive.
- Pick windows, displays and regions directly on the desktop, as in
  screenshot apps: highlight under the pointer, select by click.
- Turn the effect on and off from the menu bar.
- Adjust blur, background brightness and transition duration.
- No permissions: neither Accessibility nor Screen Recording.

## 3. Behaviour

### 3.1 Focus

- What counts is the work window: the frontmost normal window (level 0) of
  the frontmost app. Without Accessibility this is an estimate from the window
  order and is therefore always `uncertain`.
- Popups, suggestion lists and sheets are often separate normal windows of
  the same app in front of the real one. Such a window that is less than half
  the size of a window of the app behind it and lies mostly on it counts as
  associated: it stays sharp, and the larger window remains the work window.
- A click on a blurred window reaches the real window. Effect surfaces never
  take focus and never intercept input.
- While Sonorus itself is frontmost (menu, selection), the previous work
  window is kept as long as it exists.
- Without a recognizable work window nothing is blurred; the menu shows
  “No focused window detected”.
- The effect pauses during the window switcher and Mission Control.

### 3.2 Scopes

1. **All Displays**
2. **Selected Displays**
3. **Regions:** the union of all enabled rectangles; overlaps do not
   strengthen the effect.

The scopes are mutually exclusive. Computation:

```text
effect area = scope (including the desktop background)
            − visible parts of protected windows
```

Protected are the work window, its associated windows and the exceptions.
Only normal app windows shape the masks: higher levels (Dock, menu bar,
floating panels) lie above the effect surfaces anyway, lower levels
(wallpaper, desktop icons, widgets) belong to the blurred background. An
exception is no cut-out through windows in front of it; a window that only
intersects a region is only treated inside it.

### 3.3 Regions

- Create any number of rectangles; select, move, resize via handles, delete
  and disable them individually.
- A rectangle belongs to exactly one display; drawing is clamped to its edge.
- Coordinates are stored relative to the display and follow changes of
  arrangement, resolution and scale.
- If a region's display is not connected, the region pauses instead of
  moving to another display.

### 3.4 Exceptions

- Mark several windows in one selection pass; list them in the menu and
  remove them individually. Several windows of the same app are numbered.
- An exception lasts as long as its window. Minimized or hidden windows keep
  it; a closed window loses it.
- A window ID reused after closing inherits no exception (generation per
  window reference).
- Exceptions are not saved.

## 4. Direct selection

### 4.1 Flow

1. Start the selection from the menu. The effect is hidden and the work
   window is remembered.
2. Every display gets an overlay with a slight dim; a toolbar at the top
   offers the modes Windows, Displays and Regions.
3. Changes only affect a copy. Return applies everything, Esc discards the
   whole pass. A display change cancels the selection.
4. On apply, the changes of every mode are kept. The scope follows the last
   display or region mode used, but never switches to an empty selection.
5. Afterwards the focus is resolved again and the effect is updated.

Keys: `1`, `2`, `3` switch the mode, `Tab` / `⇧Tab` step through the regions,
`⌫` deletes, Space disables or enables the selected region. Clicks on the
toolbar never reach the window below. VoiceOver describes the mode and
announces changes of the selection.

### 4.2 Windows

- The frontmost window under the pointer is highlighted; own windows and
  system surfaces cannot be selected.
- A click selects, another click on the same window deselects.

### 4.3 Displays

- The display under the pointer is highlighted at its edge and labelled; a
  click selects or deselects it, several can be selected.
- Identical displays without a distinguishable identity cannot be selected
  and are labelled as such.

### 4.4 Regions

- Drag a rectangle with a crosshair; its size is shown while dragging.
- Repeated clicks step through overlapping regions; with `⌥` a new rectangle
  starts inside an existing one.

## 5. Menu

The popover is the only user interface; there is no settings window.

- **Header:** icon, “Focus”, a status line and the main switch. The status
  line explains why nothing is blurred although the effect is on (no display
  selected, displays not connected, no active region, no focused window).
- **Scope:** choice of the scope, a summary (“3 regions, 1 paused,
  1 disabled”) and access to the direct selection.
- **Effect:** blur, background brightness, transition.
- **Keep Windows Sharp:** list of exceptions and adding them via the direct
  selection.
- **Footer:** Quit (`⌘Q`), plus a note when settings cannot be saved.

Sliders:

- **Blur:** 0 to 100 %, mapped to a blur radius of 0 to 64 pt; starts at 50 %.
- **Background brightness:** 100 % leaves the brightness unchanged; starts at
  70 %. The physical display brightness is never changed.
- **Transition:** 0 to 1.5 s; starts at 750 ms. “Reduce motion” turns
  transitions off.

Slider values apply immediately and are saved debounced.

## 6. Rendering

Four variants are compared as standalone prototypes in M0
(`Experiments/Rendering/`, log in `docs/experiments/M0-rendering.md`):

| Variant | Principle | Result |
| --- | --- | --- |
| A | `NSVisualEffectView` panel above everything with a mask | Mask updates too slow; tiles as a fallback |
| B | ScreenCaptureKit and GPU blur | Needs Screen Recording; rejected |
| C | Effect panel directly below the focused window | Focused window keeps its shadow and corners; foreign windows in front need a fallback |
| D | Like C, with stepless backdrop blur and a cross-blur between two surfaces | Chosen |

Production renderer (variant D):

- Per display two display-filling surfaces with backdrop blur and dimming.
  Without the backdrop blur, a material without adjustable radius stands in;
  the menu points this out.
- **Anchored:** the surfaces lie directly below the rearmost window of the
  protected front group and show the `anchored` mask. Windows of the group
  lie above them and stay untouched.
- **Overlay:** if something foreign lies in front of the anchor or ordering
  fails, the surfaces show the `overlay` mask above the normal windows. The
  fallback only applies after a short grace period, because the window list
  often reports a new order one frame late.
- A focus change fades over to the second surface (cross-blur), so the
  background behind both surfaces stays constant.
- Mask edges are feathered.

## 7. Modules

A Swift package with one module per responsibility; every module has a test
target of the same name.

| Module | Path | Depends on | Responsibility |
| --- | --- | --- | --- |
| Contracts | `Sources/Contracts/` | – | Shared models and protocols, applying a selection |
| Geometry | `Sources/Geometry/` | Contracts | Rectangle sets, display and region conversion |
| Rules | `Sources/Rules/` | Contracts, Geometry | Effect masks and anchor from snapshot and session |
| Persistence | `Sources/Persistence/` | Contracts | Versioned, tolerant configuration file with recovery |
| Displays | `Sources/Displays/` | Contracts | Display identity and changes |
| WindowSystem | `Sources/WindowSystem/` | Contracts | Window list, lifetimes, focus, snapshots |
| Selection | `Sources/Selection/` | Contracts | Direct selection: state machine and overlay |
| Rendering | `Sources/Rendering/` | Contracts, Geometry, Rules | Effect surfaces, ordering, transitions |
| MenuBar | `Sources/MenuBar/` | Contracts | Popover and its view model |
| SonorusApp | `Sources/App/` | all | Composition, lifecycle |

Shared files: `Package.swift`, `Makefile`, `Resources/`,
`Sources/Contracts/`, `Sources/App/` and `Tests/Support/`.

## 8. Window list and energy

- The window list is read every 100 ms, immediately on workspace events, and
  at 60 Hz for 0.5 s after activations and Space changes, because raised
  windows reach the front a few frames later.
- With the effect off and no selection running, polling drops to 1 Hz
  without bursts.
- Windows that just left the screen are checked at once; windows that were
  already hidden only every 2 s and on workspace events.
- A snapshot is only published when its content changes; without a change
  nothing is rendered. Timers allow the system a tolerance.
- Nearly transparent windows (alpha < 0.05) are ignored. With separate Spaces
  per display a window is clipped to the display that shows it.

## 9. Storage and display identity

- The configuration is a versioned JSON file in
  `~/Library/Application Support/Sonorus`, written atomically and saved in
  order.
- Missing or unreadable fields get their default, a broken region is dropped
  on its own. An unusable file is moved aside with a timestamp.
- A file that can neither be read nor moved aside, or that comes from a newer
  version, is never overwritten; the menu says that changes are not saved.
- Displays are identified by their UUID, otherwise by vendor, model and
  serial number. Identical displays without a distinction are ambiguous:
  “All Displays” still treats them, display-bound scopes pause them.

## 10. Privacy

- No permissions, no screen images, no network access.
- Window titles and contents are neither used nor logged.
- Turning the effect off and quitting remove every effect surface.

## 11. Milestones

- **G0 – Scaffold:** package, modules, contracts, fixtures, `make lint`,
  `make test`, `make build`, `make app`.
- **M0 – Rendering feasibility:** variants A–D as prototypes, measurements
  and decision.
- **M1 – Core:** geometry, rules, storage, direct selection, window tracking,
  displays, renderer, menu and composition.
- **M2 – Hardening:** focus without permissions, popups and sheets, window
  switcher, idle energy, robust storage, VoiceOver support.
- **M3 – Delivery:** signing, notarization and installation.

## 12. Tests and acceptance

Automated (`make test`), deterministic and without system access:

- Rectangle algebra with negative coordinates and randomized tests against
  point sampling.
- Masks for every scope, overlaps, exceptions, anchor group, ambiguous and
  missing displays.
- Selection: hover, multi-selection, region editing, apply and cancel,
  displays with a negative origin.
- Window tracking with fake sources and manual timers.
- Renderer against a simulated window server: ordering, fallback,
  transitions.
- Storage: recovery, schema versions, failed backups.

Manual:

- Blur, edges, corners and flicker on focus changes, moving and resizing.
- Two displays with different scales, hotplug, sleep.
- Full screen, Spaces, Stage Manager, window switcher, Mission Control.
- Popups, suggestion lists and sheets of various apps.

Acceptance: the work window stays sharp and usable in every scope, nothing
intercepts input, and nothing is left behind when the effect is turned off.

## 13. Open points

- Rounded corners of the work window in the overlay fallback.
- Energy measurement with Instruments over a working day.
- Permanent exceptions per app.
- Signed delivery.
