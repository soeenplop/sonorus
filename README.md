# Sonorus

Sonorus is a macOS menu bar app that blurs and dims everything except the
active window, so your attention stays on your work.

- **Scope:** all displays, selected displays, or freely drawn regions, also
  several per display.
- **Keep windows sharp:** mark individual windows as exceptions; they stay
  sharp until they are closed.
- **Direct selection:** pick windows, displays and regions right on the
  desktop, like taking a screenshot.
- **Adjustable:** blur, background brightness and transition duration.
- **No permissions:** no Accessibility, no Screen Recording, no network
  access.

## Requirements

macOS 15 or later, Xcode 16 or later with Swift 6.

## Build and run

```sh
make app
open .build/Sonorus.app
```

Sonorus appears as an icon in the menu bar. From there you turn the effect
on, choose the scope and start the direct selection.

In the direct selection:

| Key | Action |
| --- | --- |
| `1` `2` `3` | Windows, Displays, Regions |
| `Return` | Apply |
| `Esc` | Discard |
| `Tab` / `⇧Tab` | Next / previous region |
| `⌫` | Delete region |
| Space | Disable or enable region |
| `⌥` while dragging | New region inside an existing one |

## Development

```sh
make lint
make test
make build
```

`make check` runs all three in a row, `make format` formats the code. Details
on architecture and contracts are in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md),
the plan in [`PLAN.md`](PLAN.md) and the rendering decision in
[`docs/experiments/M0-rendering.md`](docs/experiments/M0-rendering.md).

With `SONORUS_DEBUG=1 .build/Sonorus.app/Contents/MacOS/Sonorus` the app
writes one diagnostic line per changed render to stderr, without window
titles or contents.
