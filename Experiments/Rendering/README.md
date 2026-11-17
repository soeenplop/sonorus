# Rendering spike (M0)

Standalone Swift package with small, manually started prototypes for the
rendering decision. It is **not** part of the main package and is not
production code. Results and recommendation: `docs/experiments/M0-rendering.md`.

## Build and run

```sh
cd Experiments/Rendering
make build                      # debug, scratch path .build/
make lint                       # swift format lint --strict
swift run VariantA --duration 8 # or: make run T=VariantA ARGS="--duration 8"
make testapp                    # TestWindows as an .app for LaunchServices
```

Use release builds for timings:
`swift build -c release --scratch-path .build --disable-sandbox`, then
`.build/release/<Tool>`.

## Safety

- Every tool quits by itself after `--duration` seconds; `Ctrl-C`, `SIGTERM`
  and `SIGHUP` remove the overlays as well. A watchdog kills the process if
  the main thread hangs (overlays belong to the process and disappear with
  it).
- On exit the tool checks via CGWindowList that none of its windows is left
  on screen (`VERIFIED pass: cleanup …`).
- Overlays ignore mouse events and never become key or main windows.
- No tool asks for permissions unprompted. Only `VariantB --request`
  deliberately calls `CGRequestScreenCaptureAccess()`.
- Window titles are only printed with `--titles` (otherwise only their
  length).

Note: if a tool is started from a terminal while exactly that terminal is
frontmost, macOS activates the tool with its first window (inherited
activation). The tools detect this, log it and immediately hand activation
back to the previous app (can be turned off with `--keep-activation`).

## Output format

| Prefix | Meaning |
| --- | --- |
| `VERIFIED pass/FAIL` | Programmatically checked statement (e.g. z-order, hit test, cleanup) |
| `OBSERVED` | Measurement or API result without an expected value |
| `MANUAL` | Must be judged by a person looking at the screen |

## Tools

| Tool | Purpose | Permissions |
| --- | --- | --- |
| `WindowDump` | Displays (UUID, scale, coordinates), window list front→back, cost of `CGWindowListCopyWindowInfo` | none (titles only with Screen Recording) |
| `FocusProbe` | AXFocusedWindow → CGWindowList mapping, fallback without AX, `--watch N` for focus changes with AX notifications | Accessibility for the AX paths |
| `VariantA` | Effect panel above all normal windows, mask = visible parts of inactive windows | none |
| `VariantC` | Effect panel directly below the focused foreign window via `order(.below, relativeTo:)`; `--mask tiles` = hybrid C+A | none |
| `VariantB` | ScreenCaptureKit + Core Image blur + masked overlay | Screen Recording |
| `BlurBench` | GPU cost of Gaussian blur + dimming at real display sizes, offline | none |
| `TestWindows` | Controlled checkerboard windows (same titles, utility panel, focus script) | none |

### Important options

- `VariantA`: `--material hudWindow` (pass an unknown name for the list),
  `--alpha 0…1`, `--dim 0…1`, `--layers N` (stacked effect windows),
  `--mask image|tiles`, `--corner-radius 16`, `--level 1`, `--fade 180`,
  `--follow` (10 Hz poll + activation notifications), `--sweep --step 2`
  (all materials and alphas one after another), `--full` (whole screen, for a
  pure blur comparison), `--no-click-through` (control experiment),
  `--except <id,id>`.
- `VariantC`: `--follow`, `--mask full|tiles`, `--target <windowID>`,
  `--except <id,id>`, `--material`, `--alpha`, `--dim`.
- `VariantB`: `--radius <pt>`, `--dim`, `--downscale 0.5`, `--fps 30`,
  `--request`.
- `TestWindows`: `--count 3`, `--same-title`, `--panel`, `--script --step 1`.

### Automated focus scenario

```sh
make testapp
.build/release/VariantC --follow --mask tiles --duration 8 > c.log &
sleep 1.5
open -W -n --stdout tw.log .build/TestWindows.app --args --script --count 3 --duration 5
```

`TestWindows` has to be started via `open`: a process launched from the
shell may not activate itself while another app is frontmost (cooperative
activation).

## What to look for in manual tests

The blur impression, the corners and shadow of the active window, and
trailing artifacts on focus changes and while dragging. The tools print these
points as `MANUAL` lines. Full checklist: `docs/experiments/M0-rendering.md`,
section 10.

Current full-area retest (visual acceptance pending):

```sh
swift run VariantC --mask full --mask-backend native --follow --material hudWindow --transition 0.18 --menu-fade 0 --poll 0.1 --duration 90
```

`--transition` applies to `--mask full`: default 0.18 s, finite and clamped
to 0...0.6 s, 0 = instant. Only newly inactive visible areas fade in; the new
focus is protected immediately. The disjoint local effect areas do not cross
fade two full-area blurs. The default `--menu-fade 0` keeps the background
below the taller system menu bar continuous; an explicit `--menu-fade 12`
keeps the soft-fade comparison option. Headless results, resource limits and
visual limits are in the [M0 log](../../docs/experiments/M0-rendering.md).
