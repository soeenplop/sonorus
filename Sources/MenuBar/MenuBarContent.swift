import Contracts
import SwiftUI

/// Content of the `MenuBarExtra` popover (`.menuBarExtraStyle(.window)`).
public struct MenuBarContent: View {
  @Bindable private var model: MenuBarViewModel

  public init(model: MenuBarViewModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      MenuGroup { scopeSection }
      MenuGroup { effectSection }
      MenuGroup { exceptionSection }
      Divider().padding(.top, 2)
      footer
    }
    .padding(12)
    .frame(width: 320)
    .fixedSize(horizontal: false, vertical: true)
    .modifier(HiddenScrollEdges())
    .onDisappear { model.flushPendingCommit() }
  }

  // MARK: Sections

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: model.statusIcon.symbolName)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(model.isEffective ? Color.white : Color.secondary)
        .frame(width: 28, height: 28)
        .background(
          Circle().fill(model.isEffective ? Color.accentColor : Color.secondary.opacity(0.15))
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("Focus").font(.headline)
        Text(model.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle(
        "Focus", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .accessibilityValue(model.statusText)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
  }

  private var scopeSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(title: "Scope")

      // A menu picker keeps its intrinsic width; this menu spans the group.
      Menu {
        Picker(
          "Scope",
          selection: Binding(get: { model.scopeChoice }, set: { model.selectScope($0) })
        ) {
          ForEach(ScopeChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack {
          Text(model.scopeChoice.title)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel("Scope")
      .accessibilityValue(model.scopeChoice.title)

      if let title = model.selectionButtonTitle {
        Text(model.scopeSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          model.startScopeSelection()
        } label: {
          Text(title).frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var effectSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Effect")
      EffectSlider(
        title: "Blur", valueText: model.blurText,
        value: Binding(get: { model.effects.blur }, set: { model.setBlur($0) }),
        range: 0...1)
      if model.usesFallbackBlur {
        Label(
          "Simplified blur: the strength cannot be adjusted continuously on this system.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      EffectSlider(
        title: "Background Brightness", valueText: model.backgroundBrightnessText,
        value: Binding(
          get: { model.effects.backgroundBrightness }, set: { model.setBackgroundBrightness($0) }),
        range: 0...1)
      EffectSlider(
        title: "Transition", valueText: model.transitionDurationText,
        value: Binding(
          get: { model.effects.transitionDuration }, set: { model.setTransitionDuration($0) }),
        range: 0...1.5)
    }
  }

  private var exceptionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader(title: "Keep Windows Sharp")
        Spacer()
        Button {
          model.startWindowSelection()
        } label: {
          Image(systemName: "plus")
        }
        .controlSize(.small)
        .help("Add Window")
        .accessibilityLabel("Add Window")
      }

      if model.state.exceptions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Selected windows stay sharp in the background until they are closed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            model.startWindowSelection()
          } label: {
            Label("Select Windows…", systemImage: "macwindow")
              .frame(maxWidth: .infinity)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(model.state.exceptions) { exception in
            ExceptionRow(exception: exception) { model.removeException(exception) }
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack(alignment: .firstTextBaseline) {
      if let note = model.persistenceNote {
        Label(note, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Quit") { model.quit() }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .keyboardShortcut("q")
    }
    .font(.callout)
    .padding(.horizontal, 4)
  }
}

/// The window style hosts the popover in a scroll view; from macOS 26 on its
/// edge effect blurs the top and bottom margins although nothing scrolls.
private struct HiddenScrollEdges: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.scrollEdgeEffectHidden()
    } else {
      content
    }
  }
}

/// Softly filled, rounded group like the modules of Control Center.
private struct MenuGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.primary.opacity(0.05))
      )
  }
}

/// One "keep sharp" window with a remove button.
private struct ExceptionRow: View {
  let exception: MenuBarException
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "macwindow")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(exception.displayName)
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.callout)
        .help(exception.displayName)
      Spacer(minLength: 4)
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help("Remove Exception")
      .accessibilityLabel("Remove exception: \(exception.displayName)")
    }
  }
}

/// Bold title of a popover section.
private struct SectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .accessibilityAddTraits(.isHeader)
  }
}

/// Slider with title, value text and an accessibility value.
private struct EffectSlider: View {
  let title: String
  let valueText: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.callout)
        Spacer()
        Text(valueText)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Slider(value: $value, in: range) { Text(title) }
        .labelsHidden()
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
  }
}

/// Menu bar item label: icon only, with a spoken state.
public struct MenuBarLabel: View {
  private let model: MenuBarViewModel

  public init(model: MenuBarViewModel) {
    self.model = model
  }

  public var body: some View {
    let icon = model.statusIcon
    Image(systemName: icon.symbolName)
      .accessibilityLabel(icon.accessibilityLabel)
  }
}
