import Contracts

/// User intents shared by keyboard shortcuts and the toolbar.
enum SelectionCommand: Equatable {
  case setMode(SelectionMode)
  case deleteRegion
  case toggleRegion
  case nextRegion(backward: Bool)
  case confirm
  case cancel
}

enum SelectionPointerEvent: Equatable {
  case moved(ScreenPoint)
  case down(ScreenPoint, startsNewRegion: Bool)
  case dragged(ScreenPoint)
  case up(ScreenPoint)
  case left
}

extension SelectionEngine {
  mutating func apply(_ event: SelectionPointerEvent) {
    switch event {
    case .moved(let point): pointerMoved(to: point)
    case .down(let point, let startsNewRegion):
      pointerDown(at: point, startsNewRegion: startsNewRegion)
    case .dragged(let point): pointerDragged(to: point)
    case .up(let point): pointerUp(at: point)
    case .left: pointerLeft()
    }
  }

  mutating func apply(_ command: SelectionCommand) {
    switch command {
    case .setMode(let mode): setMode(mode)
    case .deleteRegion: deleteSelectedRegion()
    case .toggleRegion: toggleSelectedRegionEnabled()
    case .nextRegion(let backward): selectNextRegion(backward: backward)
    case .confirm: confirm()
    case .cancel: cancel()
    }
  }
}
