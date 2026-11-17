# Development

## Requirements and commands

macOS 15+, Xcode 16+ with Swift 6 and `swift format`. No external package
dependencies. The app uses Swift Package Manager; no Xcode project needs to
be generated. `Package.swift` can be opened in Xcode.

```sh
make lint
make test
make build
make app
open .build/Sonorus.app
```

`make check` runs lint, tests and build in a row. `make format` formats the
Swift files. `make app` creates a locally ad-hoc signed menu bar app bundle;
this is not a release signed for distribution. Sonorus needs no permissions:
the active window is estimated from the window order (frontmost normal window
of the frontmost app, `.uncertain`). Accessibility is not used. Screen
Recording is not needed.

Build output and caches live in `.build/` per checkout. Alternatively, an
absolute `BUILD_DIR` can be passed to `make`. SwiftPM's build sandbox is
disabled for these local builds; the app itself gains no additional macOS
permissions from that.

## Shared contracts

`Contracts` only depends on Foundation. All desktop snapshots are immutable
and `Sendable`. Global rectangles use Quartz coordinates in points: origin at
the top left of the main display, y pointing down. Negative values for
displays to the left or above are allowed. A `NormalizedRect` is relative to
exactly one display; Geometry handles validation, clipping and conversion.
Pixel scaling belongs at the rendering boundary.

Windows in a snapshot are ordered front to back. Sonorus overlays are
excluded. The snapshot revision is not a capture timestamp. Window references
are only valid for their window's lifetime; their generation prevents stale
exceptions from being reused. Persistable settings therefore contain no
runtime window exceptions.

AppKit services, selection and rendering run on the MainActor. IO happens
behind an asynchronous, Sendable storage protocol. Pure rule computation
needs neither AppKit nor permissions. Selection works on a copy; only
`.confirmed` may be applied to the live configuration. When a selection
starts, the work target is remembered and resolved again afterwards.

`WindowSnapshot.level` is the CoreGraphics window level, 0 is the normal
level. `frame` is the visible frame: with separate Spaces per display the
adapter clips it to the display that shows the window. Nearly transparent
windows (alpha < 0.05, e.g. while closing) are left out by the adapter.

### Background coverage and limits of the rules

By default the effect area covers the whole chosen display or region scope,
including uncovered wallpaper and desktop areas. No background window is
needed in the snapshot for that. Overlapping regions are united and do not
strengthen the effect. Only normal app windows (level 0, no system surface)
shape the masks: the overlay mask subtracts the visible parts of protected
windows (focus, associated windows, exceptions). Foreign windows in front of
them still cover exceptions; no cut-outs through them are created. Higher
levels (Dock, menu bar, floating panels) lie above the effect surfaces anyway
and therefore stay sharp. Lower levels (wallpaper, desktop icons, widgets)
belong to the blurred background; cut-outs for them produced hard, smeared
edges in user testing.

The rules use rectangular snapshot areas and the Geometry algebra. This pure
computation cannot detect or resolve unreported system surfaces, rounded
corners, transparency or outdated live geometry. Without a recognized focused
window among the reported on-screen windows, both masks stay empty. Focus is
estimated from the window order without permissions (`.uncertain`). “Reduce
transparency” is not handled separately; the controllability of the native
blur still needs human review. The smoother motion reported for variant C
compared with stuttering A tiles is evidence, not a full release acceptance.

### Rendering contract (anchored hybrid with overlay fallback)

Effect surfaces lie directly below the rearmost window of the protected front
group. This group is the leading run of normal windows (level 0, on screen,
front to back) that are all protected (focused window, associated windows,
exceptions). A `RenderAnchor` only exists if the focused window is part of
this run; `anchor.window` is its last window, `anchor.group` its set.

`RenderScene.masks` holds one `DisplayEffectMask` per `DisplayPlacement`
(runtime ID, DisplayID, frame) with two disjoint rectangle lists in global
points, clipped to the display:

- `overlay`: visible protected window and system areas stay clear. Valid for
  surfaces above all normal windows (level normal + 1).
- `anchored`: windows of the group do not occlude, because they lie above the
  surfaces. Only valid while the surfaces lie directly below the anchor;
  always a superset of `overlay`.

Without an anchor only `overlay` is valid. Placements without a mask show no
effect. Windows with a level ≠ 0 never receive the effect. Anchored
visibility only ignores the anchor group; further protected windows and
system areas behind it stay protected as long as no foreign window covers
them. System surfaces are never part of the anchor group. The runtime ID of a
placement is unique per snapshot and never stored; it distinguishes
identical displays with the same DisplayID. In “All Displays” these still
receive the effect, display-bound scopes pause them.

The renderer orders the surfaces below the anchor, then checks the actual
order and switches to `overlay` at level normal + 1 as soon as anything other
than `anchor.group` lies above the surfaces or anchoring is impossible.
Ordering and surfaces change in one CATransaction. The contracts assume no
blur source; the production renderer uses M0 variant D (see
`docs/experiments/M0-rendering.md`).

## Modules and boundaries

The modules and their dependencies are listed in `PLAN.md`, section 7. Every
module has a test target of the same name. The M0 experiments live in
`Experiments/Rendering/` with their own package; they do not change the main
manifest.

`Package.swift`, `Makefile`, `Resources/`, `Sources/Contracts/` and
`Sources/App/` are shared files: changes to them affect every module and are
integrated one at a time. Tests use deterministic fixtures from
`Tests/Support/`.

Live tests involving focus, selection and overlays run one after another in
the same macOS session; separate checkouts isolate code and build output, not
windows or the active desktop.
