import AppKit

/// Menu bar controls for live effect tuning. Status item menus do not activate
/// the spike, so the measured focus stays on the user's window.
///
/// Native behind-window blur has no public radius. "Blur" is the effect view's
/// opacity (a cross-fade between sharp and blurred); the material sets the
/// base strength. Whether that reads as adjustable blur is the T1 question.
@MainActor
public final class EffectControls: NSObject {
  public struct Values: Equatable {
    public var material: NSVisualEffectView.Material
    public var blur: CGFloat
    public var dim: CGFloat

    public init(material: NSVisualEffectView.Material, blur: CGFloat, dim: CGFloat) {
      self.material = material
      self.blur = blur
      self.dim = dim
    }
  }

  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var values: Values
  private let onChange: @MainActor (Values) -> Void
  private let blurLabel = NSTextField(labelWithString: "")
  private let dimLabel = NSTextField(labelWithString: "")
  private let materialMenu = NSMenu()
  private let blurTitle: (CGFloat) -> String

  public init(
    values: Values,
    blurTitle: @escaping (CGFloat) -> String = { "Blur: \(Int(($0 * 100).rounded())) %" },
    onChange: @escaping @MainActor (Values) -> Void
  ) {
    self.values = values
    self.blurTitle = blurTitle
    self.onChange = onChange
    super.init()
    item.button?.image = NSImage(
      systemSymbolName: "camera.filters", accessibilityDescription: "Effekt-Regler")
    let menu = NSMenu()
    menu.addItem(sliderItem(label: blurLabel, value: values.blur, action: #selector(blurChanged)))
    menu.addItem(sliderItem(label: dimLabel, value: values.dim, action: #selector(dimChanged)))
    menu.addItem(.separator())
    for (name, material) in Materials.all {
      let entry = NSMenuItem(title: name, action: #selector(materialChosen), keyEquivalent: "")
      entry.target = self
      entry.representedObject = name
      entry.state = material == values.material ? .on : .off
      materialMenu.addItem(entry)
    }
    let materials = NSMenuItem(title: "Material", action: nil, keyEquivalent: "")
    materials.submenu = materialMenu
    menu.addItem(materials)
    item.menu = menu
    updateLabels()
    Log.manual("menu bar icon (camera filters): adjust blur, dim and material live")
  }

  public func remove() { NSStatusBar.system.removeStatusItem(item) }

  private func sliderItem(label: NSTextField, value: CGFloat, action: Selector) -> NSMenuItem {
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 48))
    label.frame = CGRect(x: 16, y: 26, width: 228, height: 18)
    label.font = .menuFont(ofSize: 0)
    let slider = NSSlider(
      value: Double(value), minValue: 0, maxValue: 1, target: self, action: action)
    slider.frame = CGRect(x: 14, y: 4, width: 232, height: 20)
    slider.isContinuous = true
    view.addSubview(label)
    view.addSubview(slider)
    let item = NSMenuItem()
    item.view = view
    return item
  }

  private func updateLabels() {
    blurLabel.stringValue = blurTitle(values.blur)
    dimLabel.stringValue = "Abdunklung: \(Int((values.dim * 100).rounded())) %"
  }

  private func changed() {
    updateLabels()
    onChange(values)
  }

  @objc private func blurChanged(_ sender: NSSlider) {
    values.blur = CGFloat(sender.doubleValue)
    changed()
  }

  @objc private func dimChanged(_ sender: NSSlider) {
    values.dim = CGFloat(sender.doubleValue)
    changed()
  }

  @objc private func materialChosen(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String, let material = Materials.named(name)
    else { return }
    for entry in materialMenu.items { entry.state = entry === sender ? .on : .off }
    values.material = material
    changed()
  }
}
