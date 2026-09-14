import AppKit
import SwiftUI
import RewriteCore

// MARK: - Accessibility snapshot

/// The three system accessibility settings the overlay is required to honor,
/// sampled once per presentation.
///
/// These are read from `NSWorkspace` rather than from the SwiftUI environment
/// on purpose. The SwiftUI values (`\.accessibilityReduceMotion` and friends)
/// are populated for views inside an app's normal window hierarchy; this view
/// lives in an `NSHostingView` inside a borderless non-activating panel that is
/// never key and never part of a `WindowGroup`, and relying on environment
/// propagation into that context is a bet we do not need to take. `NSWorkspace`
/// is the source those environment values come from anyway.
///
/// Sampled at `show()` rather than observed continuously: the panel lives for a
/// few seconds, and the alternative is a `NSWorkspace.notificationCenter`
/// observer whose lifetime has to be managed across the same paths that already
/// manage the key monitors. One thing that can leak is better than two, and a
/// user who flips Reduce Motion during a three second rewrite sees the new
/// setting on the next one.
struct PanelAppearance: Equatable, Sendable {
    /// No transitions, no spinners. A spinner is not decoration to someone with
    /// a vestibular disorder.
    var reduceMotion: Bool
    /// Solid background instead of a blur. Translucency over arbitrary
    /// underlying content is the single worst thing you can do to text contrast,
    /// and this panel floats over content it has no control over.
    var reduceTransparency: Bool
    /// Heavier borders and no low-contrast secondary text.
    var increaseContrast: Bool

    static let `default` = PanelAppearance(
        reduceMotion: false,
        reduceTransparency: false,
        increaseContrast: false
    )

    @MainActor
    static var current: PanelAppearance {
        let workspace = NSWorkspace.shared
        return PanelAppearance(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }

    /// Secondary text stops being secondary under Increase Contrast. The user
    /// asked for legibility, not hierarchy.
    var secondaryTextColor: Color {
        increaseContrast ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
    }

    var borderWidth: CGFloat { increaseContrast ? 2 : 1 }

    var borderColor: Color {
        increaseContrast
            ? Color(nsColor: .labelColor)
            : Color(nsColor: .separatorColor)
    }

    /// The panel's fill. Material when allowed, an opaque window colour when
    /// not. Both are shape styles, so the call site does not branch.
    var backgroundStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(.regularMaterial)
    }

    /// `nil` disables the animation entirely, which is what `withAnimation` and
    /// the `.animation(_:value:)` modifier both want for Reduce Motion.
    var transition: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

// MARK: - Chrome

/// The panel's background, drawn behind the scrolling content rather than
/// inside it.
///
/// If the background travelled with the content, then in the one case that
/// matters (a long rewrite, content taller than the 40% height cap, internal
/// scrolling) the rounded bottom corners would scroll up out of view and leave
/// two square transparent notches at the bottom of the panel. Keeping the
/// chrome pinned to the window and the text scrolling over it is one extra view
/// and removes that whole class of glitch.
struct PanelChrome: View {
    /// Observes the model rather than taking a `PanelAppearance` value, because
    /// this view is hosted once when the panel is built and the appearance is
    /// re-sampled on every `show()`. A snapshot passed in at construction would
    /// be the accessibility settings as they were the first time the user ever
    /// pressed the hotkey.
    @ObservedObject var model: PanelModel

    private var appearance: PanelAppearance { model.appearance }

    var body: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
            .fill(appearance.backgroundStyle)
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
            .accessibilityHidden(true)
    }
}

/// Shared geometry. The controller needs the width to size the window and the
/// view needs it to lay out, so it cannot live in either one alone.
enum PanelMetrics {
    static let width: CGFloat = 460
    static let cornerRadius: CGFloat = 14
    static let padding: CGFloat = 16
    /// Enough for a one-line state with no body text. Stops the window from
    /// collapsing to nothing for a frame during the first render.
    static let minHeight: CGFloat = 64
    /// Fraction of the containing screen's `visibleFrame` the panel may occupy
    /// before the content starts scrolling instead of growing.
    static let maxHeightFraction: CGFloat = 0.40
    /// Gap between the bottom of the panel and the bottom of `visibleFrame`.
    /// `visibleFrame` already excludes the Dock, so this is breathing room, not
    /// Dock avoidance.
    static let bottomMargin: CGFloat = 48
}

// MARK: - The panel content

/// The whole panel, as a pure function of `PanelModel`.
///
/// Nothing in here starts work, cancels work, or knows what an engine is. It
/// reads `model.state` and calls back through the closures the controller
/// installed on the model. That boundary is why the same view renders correctly
/// for a state that was pushed by a live transaction and for one typed into a
/// debug menu.
struct RewriteView: View {
    @ObservedObject var model: PanelModel

    private var appearance: PanelAppearance { model.appearance }
    private var state: PanelState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let detail = state.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(appearance.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .preparing(let progress) = state {
                progressBar(progress)
            }

            if let body = state.bodyText, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Rewritten text")
                    .accessibilityValue(body)
            }

            if case .stylePicker(let presets) = state {
                StylePickerView(
                    presets: presets,
                    selectedIndex: model.selectedStyleIndex,
                    appearance: appearance,
                    onPick: { model.pickStyle($0) }
                )
            }

            footer
        }
        .padding(PanelMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(appearance.transition, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Everest rewrite panel")
        .accessibilityValue(state.accessibilityLabel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Symbol first, and present in every single state. This is the
            // non-colour half of the signal; see PanelState's presentation
            // extension for why that is not negotiable.
            Image(systemName: state.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolColor)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityHidden(true)

            Text(state.title)
                .font(.headline)
                .foregroundStyle(Color(nsColor: .labelColor))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if state.showsActivity && !appearance.reduceMotion && !isDeterminatePreparing {
                // Only an indeterminate spinner is suppressed under Reduce
                // Motion. A determinate bar is positional information and is
                // rendered below the header instead.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            if state.isCancellable {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Cancel rewrite")
                    .accessibilityHint("Stops this rewrite and closes the panel. Escape does the same.")
            }
        }
    }

    private var isDeterminatePreparing: Bool {
        if case .preparing(let progress) = state { return progress != nil }
        return false
    }

    /// Colour is applied last and carries nothing on its own. Every one of
    /// these states is already distinguishable with the colour stripped out.
    private var symbolColor: Color {
        if appearance.increaseContrast { return Color(nsColor: .labelColor) }
        switch state {
        case .success: return .green
        case .refused, .error: return .orange
        case .targetChanged: return .orange
        default: return Color(nsColor: .secondaryLabelColor)
        }
    }

    // MARK: Progress

    @ViewBuilder
    private func progressBar(_ progress: Double?) -> some View {
        if let progress {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .accessibilityLabel("Model download progress")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        } else if appearance.reduceMotion {
            // An indeterminate bar animates forever, which is exactly what
            // Reduce Motion is asking us not to do. The words in the header
            // already say what is happening.
            EmptyView()
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Preparing model")
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let hint = footerHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(appearance.secondaryTextColor)
                .accessibilityLabel(hint)
        }
    }

    private var footerHint: String? {
        switch state {
        case .stylePicker(let presets):
            let last = min(presets.count, 5)
            return last > 1
                ? "Press 1 to \(last), or use the arrow keys and Return. Escape cancels."
                : "Press Return to choose. Escape cancels."
        case .capturing, .preparing, .generating:
            return "Escape cancels."
        case .applying, .success, .readOnly, .targetChanged, .refused, .error:
            return nil
        }
    }
}
