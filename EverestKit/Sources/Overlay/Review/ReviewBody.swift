import AppKit
import SwiftUI

/// The review state's body: the editor, or the tracked changes. Which one is
/// `PanelState.changes`' answer, and the runs come from it; nothing here
/// decides anything.
struct ReviewBody: View {
    let state: PanelState
    let editor: EditorSlot
    let appearance: PanelAppearance

    var body: some View {
        if let changes = state.changes {
            Text(attributed(changes))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(field)
        } else if case let .review(text, _, _, _) = state {
            ReviewEditor(text: text, slot: editor)
                .background(field)
        }
    }

    /// An inset field in both appearances; the border thickens under
    /// Increase Contrast like the keycaps.
    private var field: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.separator, lineWidth: appearance.borderWidth)
            )
    }

    /// Struck through for removed, underlined for added: shape first, so the
    /// marks survive a reader who cannot tell the red from the green.
    private func attributed(_ segments: [DiffSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case let .same(text):
                result += AttributedString(text)
            case let .removed(text):
                var run = AttributedString(text)
                run.strikethroughStyle = .single
                run.foregroundColor = Color(nsColor: .systemRed)
                run.backgroundColor = Color(nsColor: .systemRed).opacity(0.14)
                result += run
            case let .added(text):
                var run = AttributedString(text)
                run.underlineStyle = .single
                run.foregroundColor = Color(nsColor: .systemGreen)
                run.backgroundColor = Color(nsColor: .systemGreen).opacity(0.16)
                result += run
            }
        }
        return result
    }
}
