import RewriteCore
import SwiftUI

/// The panel's content. Integration only, in the sense that nothing here
/// decides anything: every string, symbol, colour rule and progress style is
/// read off `PanelState` or `PanelAppearance`, both of which are tested. If you
/// find yourself writing an `if` about *what* to show, it belongs in one of
/// those two types instead.
struct RewriteView: View {
    let state: PanelState
    let appearance: PanelAppearance
    let highlightedStyleIndex: Int
    let onCopy: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onPickStyle: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if case let .stylePicker(presets) = state {
                StylePickerView(
                    presets: presets,
                    highlightedIndex: highlightedStyleIndex,
                    appearance: appearance,
                    onPick: onPickStyle
                )
            } else if let bodyText = state.bodyText {
                Text(bodyText)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !state.keyHints.isEmpty {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    ForEach(state.keyHints, id: \.keys) { hint in
                        keycap(hint)
                    }
                }
            }
        }
        // The same padding `PanelGeometry.bodyWidth` subtracts, so the width a
        // long URL is tested against is the width it is actually drawn at.
        .padding(PanelGeometry.contentPadding)
        .frame(width: PanelGeometry.preferredWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Everest")
        .accessibilityValue(state.accessibilityValue)
    }

    /// The hint *is* the control: keycap, words, and clickable. One affordance
    /// rather than a button beside a caption, which left a bare glyph in one
    /// corner and its label in the other.
    ///
    /// Shape and weight carry the meaning, not colour — under Increase
    /// Contrast the capsule keeps its border and the text goes full strength.
    @ViewBuilder
    private func keycap(_ hint: KeyHint) -> some View {
        if let performs = hint.performs {
            Button { perform(performs) } label: { badge(hint) }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: performs))
        } else {
            // No action, so no button: a control that looks clickable and
            // answers nothing is the thing the clickable-row rule is for.
            // Hidden from VoiceOver like every other badge — the picker's
            // rows already announce "1. Concise", so the numbers reach a
            // screen reader from the list rather than from here.
            badge(hint).accessibilityHidden(true)
        }
    }

    private func badge(_ hint: KeyHint) -> some View {
        HStack(spacing: 4) {
                Text(hint.keys)
                    .font(.caption.weight(.medium))
                    .monospaced()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.separator, lineWidth: appearance.borderWidth)
                    )
                Text(hint.action)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .foregroundStyle(
                appearance.dimsSecondaryText ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
            )
            // The badge is decoration for the eye. A screen reader hears the
            // key equivalent through the standard mechanism, and "Copy command
            // C" read as a label is noise.
            .accessibilityHidden(true)
    }

    private func perform(_ action: PanelKeyAction) {
        switch action {
        case .copy:    onCopy()
        case .cancel:  onCancel()
        // Never produced by `keyHints`; the picker's keys have their own rows.
        case .pickStyle, .commitHighlightedStyle, .moveHighlight: break
        }
    }

    private func accessibilityLabel(for action: PanelKeyAction) -> String {
        switch action {
        case .copy:    "Copy the rewrite to the clipboard"
        case .cancel:  "Close this panel"
        case .pickStyle, .commitHighlightedStyle, .moveHighlight: ""
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Never colour alone: the symbol and the words both carry the
            // state, and under Increase Contrast the tint is dropped entirely.
            Image(systemName: state.symbolName)
                .foregroundStyle(appearance.tintsStateSymbol ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                if let detail = state.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(appearance.dimsSecondaryText ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }

            Spacer(minLength: 8)
            if let hint = state.headerNote {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(appearance.dimsSecondaryText ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            progress
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch appearance.progressStyle(for: state) {
        case .hidden:
            EmptyView()
        case .indeterminate:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case let .determinate(fraction):
            ProgressView(value: fraction)
                .frame(width: 80)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(fraction * 100))%")
        }
    }
}
