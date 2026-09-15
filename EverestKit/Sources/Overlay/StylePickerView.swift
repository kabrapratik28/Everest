import RewriteCore
import SwiftUI

/// The numbered list behind ⌘⇧I.
///
/// Not a `List(selection:)`. A non-activating panel is never key, so nothing in
/// it is ever first responder and a `List`'s selection never moves with the
/// arrow keys. The highlight is a plain `Int` the controller owns and the key
/// monitor moves.
struct StylePickerView: View {
    let presets: [Preset]
    let highlightedIndex: Int
    let appearance: PanelAppearance
    let onPick: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                row(index: index, preset: preset)
            }
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
