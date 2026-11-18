import AppKit
import Contracts

/// Controls in a non-key overlay must react to the very first click.
private final class FirstMouseSegmentedControl: NSSegmentedControl {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Compact HUD toolbar: mode switch, region actions, cancel and confirm.
final class SelectionToolbarView: NSVisualEffectView {
  static let cornerRadius: CGFloat = 12

  var onCommand: (SelectionCommand) -> Void = { _ in }

  private let modes: [SelectionMode] = [.windows, .displays, .regions]
  private let modeControl: FirstMouseSegmentedControl
  private let deleteButton: FirstMouseButton
  private let toggleButton: FirstMouseButton
  private let separator = NSBox()

  override init(frame frameRect: NSRect) {
    modeControl = FirstMouseSegmentedControl(
      labels: ["Windows", "Displays", "Regions"], trackingMode: .selectOne, target: nil,
      action: nil)
    deleteButton = FirstMouseButton(title: "Delete", target: nil, action: nil)
    toggleButton = FirstMouseButton(title: "Disable", target: nil, action: nil)
    super.init(frame: frameRect)
    material = .hudWindow
    // Blurs the desktop itself, not the scrim and highlights of the overlay.
    blendingMode = .behindWindow
    state = .active
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor

    let symbols = ["macwindow", "display", "rectangle.dashed"]
    let tips = [
      "Keep windows sharp (1)", "Select displays (2)", "Edit regions (3)",
    ]
    for (index, symbol) in symbols.enumerated() {
      modeControl.setImage(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: index)
      modeControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
      modeControl.setToolTip(tips[index], forSegment: index)
    }
    modeControl.target = self
    modeControl.action = #selector(modeChanged)
    modeControl.segmentStyle = .capsule

    configure(deleteButton, symbol: "trash", action: #selector(deleteTapped))
    configure(toggleButton, symbol: "pause.circle", action: #selector(toggleTapped))
    deleteButton.toolTip = "Delete the selected region (⌫)"
    toggleButton.toolTip = "Disable or enable the selected region (Space)"

    let cancel = FirstMouseButton(title: "Cancel", target: self, action: #selector(cancelTapped))
    cancel.bezelStyle = .rounded
    cancel.toolTip = "Discard all changes (Esc)"
    let confirm = FirstMouseButton(
      title: "Apply", target: self, action: #selector(confirmTapped))
    confirm.bezelStyle = .rounded
    confirm.bezelColor = .controlAccentColor
    confirm.toolTip = "Apply the selection (Return)"

    separator.boxType = .separator
    let stack = NSStackView(views: [
      modeControl, deleteButton, toggleButton, separator, cancel, confirm,
    ])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func configure(_ button: NSButton, symbol: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
    button.imagePosition = .imageLeading
    button.bezelStyle = .rounded
    button.target = self
    button.action = action
  }

  /// Syncs the controls with the scene; region actions only exist in region mode.
  func update(with scene: SelectionScene) {
    if let index = modes.firstIndex(of: scene.mode) { modeControl.selectedSegment = index }
    let selected = scene.regions.first { $0.isSelected }
    let showsRegionActions = scene.mode == .regions
    deleteButton.isHidden = !showsRegionActions
    toggleButton.isHidden = !showsRegionActions
    separator.isHidden = !showsRegionActions
    deleteButton.isEnabled = selected != nil
    toggleButton.isEnabled = selected != nil
    let disabled = selected.map { !$0.isEnabled } ?? false
    toggleButton.title = disabled ? "Enable" : "Disable"
    toggleButton.image = NSImage(
      systemSymbolName: disabled ? "checkmark.circle" : "circle.slash",
      accessibilityDescription: nil)
  }

  @objc private func modeChanged() {
    guard modes.indices.contains(modeControl.selectedSegment) else { return }
    onCommand(.setMode(modes[modeControl.selectedSegment]))
  }

  @objc private func deleteTapped() { onCommand(.deleteRegion) }
  @objc private func toggleTapped() { onCommand(.toggleRegion) }
  @objc private func cancelTapped() { onCommand(.cancel) }
  @objc private func confirmTapped() { onCommand(.confirm) }
}
