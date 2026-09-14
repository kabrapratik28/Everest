import SwiftUI
import RewriteCore

/// The ⌘⇧I style list.
///
/// A numbered list, not a `List` and not a `Picker`.
///
/// The panel is a non-activating `NSPanel`, so it is never the key window and
/// nothing inside it can ever be first responder. Every SwiftUI selection
/// control assumes the opposite: `List` selection, `@FocusState`, `.focusable`,
/// `.onKeyPress` and `.keyboardShortcut` all route through the responder chain
/// and all of them are dead here. So the keyboard half of this control lives in
/// `FloatingPanelController`'s event monitor, which pushes a plain `Int` into
/// `PanelModel.selectedStyleIndex`, and this view is a passive renderer of that
/// integer. Do not "modernise" this into a `List(selection:)`: it will look
/// right in a preview, compile, and then do nothing at all when the panel is on
/// screen over another app.
///
/// The visible numbers are not decoration either. They are the actual
/// instructions: the keys 1 through 5 are the fast path and the arrow keys are
/// the fallback, so the number has to be on screen next to the thing it picks.
struct StylePickerView: View {
    var presets: [Preset]
    /// Driven by the controller's key monitor. Clamped here rather than
    /// trusted, because the state and the index are published separately and
    /// can be one update out of step.
    var selectedIndex: Int
    var appearance: PanelAppearance
    var onPick: (Preset) -> Void

    /// Only the first five get a number key. A sixth custom style is still
    /// reachable with the arrow keys, and gets no digit rather than a wrong one.
    private static let maxNumberedRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                row(index: index, preset: preset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rewrite styles")
    }

    private func row(index: Int, preset: Preset) -> some View {
        let isSelected = index == clampedSelection

        return Button {
            onPick(preset)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                numberBadge(index: index, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        // Weight, not colour. Under Increase Contrast, and for
                        // anyone who cannot separate the selected row's tint
                        // from the material behind it, the bold name and the
                        // chevron are what say "this one".
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(appearance.secondaryTextColor)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.secondaryTextColor)
                    // Hidden rather than absent, so the row does not change
                    // width as the selection moves.
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(index: index, preset: preset))
        .accessibilityHint("Rewrites the selected text in this style.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func numberBadge(index: Int, isSelected: Bool) -> some View {
        if index < Self.maxNumberedRows {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    appearance.borderColor,
                                    lineWidth: appearance.increaseContrast ? 1 : 0
                                )
                        }
                }
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(appearance.increaseContrast ? 0.45 : 0.25))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            appearance.borderColor,
                            lineWidth: appearance.increaseContrast ? appearance.borderWidth : 0
                        )
                }
        } else {
            Color.clear
        }
    }

    /// Spoken as "3, Concise, cut to the essentials, selected". The number is
    /// read because it is a usable instruction, not because it is on screen.
    private func accessibilityLabel(index: Int, preset: Preset) -> String {
        var parts: [String] = []
        if index < Self.maxNumberedRows { parts.append("\(index + 1)") }
        parts.append(preset.name)
        parts.append(preset.subtitle)
        return parts.joined(separator: ", ")
    }

    private var clampedSelection: Int {
        guard !presets.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), presets.count - 1)
    }
}
