// A screenshot GENERATOR, not a test. It asserts nothing about behaviour.
//
// It lives in the test target for one reason: `RewriteView` and
// `StylePickerView` are internal, and `@testable import` is the only way to
// reach them without making them public. Making production types public to
// serve a screenshot tool would be a YAGNI violation, so this is the lesser
// evil and the standard Swift snapshot-testing arrangement.
//
// It is skipped unless EVEREST_SCREENSHOTS=1, so it never runs in the normal
// suite and never slows anyone down.
//
//   EVEREST_SCREENSHOTS=1 swift test --filter ScreenshotGenerator
//
// Output: ~/Desktop/Everest-UI/
import Testing
import SwiftUI
import AppKit
@testable import Overlay
@testable import RewriteCore

@MainActor
struct ScreenshotGenerator {

    static let outputDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Desktop/Everest-UI")

    /// The real panel width, so what you see is the width you get.
    static let panelWidth: CGFloat = 460

    // Roughly a full paragraph of rewritten prose, to exercise wrapping and the
    // height cap rather than a toy string.
    static let longText = """
        Thanks for the update. I reviewed the numbers last night and the \
        picture is clearer than it was on Tuesday: the drop is concentrated in \
        one cohort rather than spread across the base, which is a much easier \
        problem to fix. I would rather we hold the launch a week than ship \
        into a trend we do not understand yet. Happy to walk through the \
        detail whenever suits you, and I can have the breakdown ready by \
        Thursday morning if that helps the decision.
        """

    // A URL with no spaces. This is the case that visibly breaks naive layout,
    // and people rewrite text containing links constantly.
    static let unbrokenToken = """
        See the thread here for context: \
        https://internal.example.com/dashboards/retention/cohort-analysis-2026-q3?window=28d&segment=new_users&compare=previous_period&breakdown=acquisition_channel \
        and let me know what you think.
        """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EVEREST_SCREENSHOTS"] == "1"))
    func generate() throws {
        try? FileManager.default.createDirectory(
            at: Self.outputDir, withIntermediateDirectories: true)

        // ImageRenderer cannot rasterise a ProgressView: it substitutes a
        // yellow placeholder glyph, which reads as a broken UI element in a
        // screenshot. `reduceMotion: true` makes progressStyle return .hidden
        // for the spinner states, which is otherwise visually identical in a
        // still image (reduceMotion only suppresses animation). So the shots
        // are honest rather than showing a control that is not there.
        //
        // .preparing(progress:) still renders a determinate bar regardless of
        // reduceMotion, so that one state is generated with progress nil and
        // captioned in the README instead.
        let plain = PanelAppearance(
            reduceMotion: true, reduceTransparency: false, increaseContrast: false)
        let accessible = PanelAppearance(
            reduceMotion: true, reduceTransparency: true, increaseContrast: true)

        let styles = Preset.builtInStyles

        // Name → (state, appearance, colour scheme). Ordered so the streaming
        // states the user actually asked about come first.
        let shots: [(String, PanelState, PanelAppearance, ColorScheme)] = [
            ("01-streaming-short",      .generating(text: "Thanks for the update. I'll review the numbers tonight and get back to you"), plain, .dark),
            ("02-streaming-long",       .generating(text: Self.longText), plain, .dark),
            ("03-streaming-long-url",   .generating(text: Self.unbrokenToken), plain, .dark),
            ("04-streaming-light",      .generating(text: Self.longText), plain, .light),
            ("05-style-picker",         .stylePicker(presets: styles), plain, .dark),
            ("06-preparing",            .preparing(progress: nil), plain, .dark),
            ("07-capturing",            .capturing, plain, .dark),
            ("08-success",              .success, plain, .dark),
            ("09-read-only",            .readOnly(text: Self.longText), plain, .dark),
            ("10-held-for-manual-copy", .heldForManualCopy(text: Self.longText, reason: "Your clipboard holds something too large to restore safely, so Everest did not touch it."), plain, .dark),
            ("11-refused",              .refused(reason: "Apple's on-device model declined to rewrite this text. Try the Qwen engine in Settings."), plain, .dark),
            ("12-error",                .error(reason: "Everest no longer has Accessibility permission."), plain, .dark),
            ("13-target-changed",       .targetChanged(text: Self.longText), plain, .dark),
            // Reduce Transparency + Increase Contrast, to prove the
            // accessibility path renders and is not an untested branch.
            ("14-accessible-contrast",  .generating(text: Self.longText), accessible, .dark),
        ]

        var written: [String] = []
        for (name, state, appearance, scheme) in shots {
            let view = RewriteView(
                state: state,
                appearance: appearance,
                highlightedStyleIndex: 0,
                onCopy: {},
                onCancel: {},
                onPickStyle: { _ in }
            )
            .frame(width: Self.panelWidth)
            // The real chrome lives in NSPanelSurface, not in RewriteView:
            // an NSVisualEffectView with material .hudWindow, cornerRadius 14,
            // a separator-coloured border, and a window shadow. Re-created here
            // so the screenshot shows what ships. ImageRenderer cannot rasterise
            // a live vibrancy material, so this is a flat stand-in for it; the
            // real panel is translucent and picks up the desktop behind it.
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark
                          ? Color(red: 0.16, green: 0.17, blue: 0.19)
                          : Color(red: 0.96, green: 0.96, blue: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18),
                                  lineWidth: appearance.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .environment(\.colorScheme, scheme)
            // A desktop-ish backdrop, so the corner radius and shadow read.
            .padding(34)
            .background(scheme == .dark
                ? Color(red: 0.08, green: 0.09, blue: 0.11)
                : Color(red: 0.80, green: 0.82, blue: 0.86))

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2  // Retina

            guard let cg = renderer.cgImage else {
                Issue.record("Renderer produced no image for \(name)")
                continue
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("PNG encode failed for \(name)")
                continue
            }
            let url = Self.outputDir.appending(path: "\(name).png")
            try png.write(to: url)
            written.append("\(name).png  \(cg.width)x\(cg.height)")
        }

        print("\n=== wrote \(written.count) screenshots to \(Self.outputDir.path) ===")
        written.forEach { print("  \($0)") }
    }
}
