import RewriteCore
import SwiftUI

/// The numbered list behind the Choose Style hotkey.
///
/// Not a `List(selection:)`. A non-activating panel is never key, so nothing in
/// it is ever first responder and a `List`'s selection never moves with the
/// arrow keys. The highlight is a plain `Int` the controller owns and the key
/// monitor moves.
struct StylePickerView: View {
    /// Where the style list comes from, said on the one screen that shows it.
    ///
    /// `AppSettings.styles` is user-editable and uncapped — `PanelKeyMap`
    /// numbers nine rows precisely because people add their own — and nothing
    /// here said so, so the six shipped styles read as the whole product.
    ///
    /// **"Prompts", because that is the tab's actual name.** It is not
    /// "Styles", which is what it edits. Checked against `SettingsView`
    /// rather than assumed: naming a surface that does not exist is the
    /// failure `ShortcutCopy` was written about, and this is the same class.
    ///
    /// No shortcut glyph here. Panel shortcuts are shown as keycap badges via
    /// `PanelState.keyHints`, and a second, hand-written copy of a binding in
    /// prose is the thing that went stale three times.
    static let settingsHint = "Add or edit these in Settings ▸ Prompts"

    let presets: [Preset]
    let highlightedIndex: Int
    let appearance: PanelAppearance
    let onPick: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                row(index: index, preset: preset)
            }

            // Below the rows and visually quieter than a subtitle: it is an
            // aside, and the rows are what the user is here to read. Not a
            // keycap badge — `keyHints` badges are clickable controls for a
            // `PanelKeyAction`, and this performs nothing.
            Divider()
                .padding(.top, 4)
            Text(Self.settingsHint)
                .font(.caption)
                .foregroundStyle(
                    appearance.dimsSecondaryText
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                )
                .padding(.horizontal, 6)
                .padding(.top, 2)
        }
    }

    private func row(index: Int, preset: Preset) -> some View {
        let isHighlighted = index == highlightedIndex
        // A row past the numbered ones is still reachable with the arrows and
        // gets no number rather than a wrong one.
        let number = index < PanelKeyMap.numberedRows ? String(index + 1) : nil

        return Button {
            onPick(index)
        } label: {
            HStack(spacing: 10) {
                Text(number ?? " ")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(appearance.dimsSecondaryText ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 14, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .fontWeight(isHighlighted ? .semibold : .regular)
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(appearance.dimsSecondaryText ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }

                Spacer(minLength: 8)

                // Held at zero opacity rather than removed, so the row does not
                // change width as the highlight moves.
                Image(systemName: "chevron.right")
                    .opacity(isHighlighted ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(number.map { "\($0). \(preset.name)" } ?? preset.name)
        .accessibilityHint(preset.subtitle)
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}
