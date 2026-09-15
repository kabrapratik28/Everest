import Testing
@testable import Overlay

@Suite("PanelAppearance")
struct PanelAppearanceTests {
    static let plain = PanelAppearance(
        reduceMotion: false,
        reduceTransparency: false,
        increaseContrast: false
    )

    @Test("Reduce Motion removes the transition between states")
    func reduceMotionRemovesTheTransition() {
        var reduced = Self.plain
        reduced.reduceMotion = true

        #expect(Self.plain.animatesStateChange == true)
        #expect(reduced.animatesStateChange == false)
    }

    /// An indeterminate spinner animates forever, which is the exact thing
    /// Reduce Motion asks us not to do. A determinate bar carries position
    /// rather than motion for its own sake, so it stays.
    @Test("Reduce Motion suppresses indeterminate spinners but keeps a determinate bar")
    func reduceMotionSuppressesOnlyIndeterminateProgress() {
        var reduced = Self.plain
        reduced.reduceMotion = true

        #expect(Self.plain.progressStyle(for: .generating(text: "x")) == .indeterminate)
        #expect(reduced.progressStyle(for: .generating(text: "x")) == .hidden)

        #expect(Self.plain.progressStyle(for: .preparing(progress: nil)) == .indeterminate)
        #expect(reduced.progressStyle(for: .preparing(progress: nil)) == .hidden)

        #expect(Self.plain.progressStyle(for: .preparing(progress: 0.4)) == .determinate(0.4))
        #expect(reduced.progressStyle(for: .preparing(progress: 0.4)) == .determinate(0.4))

        #expect(Self.plain.progressStyle(for: .success) == .hidden)
    }

    /// Translucency over arbitrary underlying content is the worst thing you
    /// can do to text contrast, and this window floats over arbitrary content
    /// by definition.
    @Test("Reduce Transparency swaps the blur material for an opaque background")
    func reduceTransparencyMakesTheBackgroundOpaque() {
        var reduced = Self.plain
        reduced.reduceTransparency = true

        #expect(Self.plain.usesTranslucentMaterial == true)
        #expect(reduced.usesTranslucentMaterial == false)
    }

    /// Under Increase Contrast the user has asked for legibility rather than
    /// visual hierarchy, so the things that exist only to rank information —
    /// a dimmed secondary line, a tinted glyph — give way to a thicker edge
    /// and full-strength text.
    @Test("Increase Contrast thickens the border and drops decorative colour")
    func increaseContrastFavoursLegibilityOverHierarchy() {
        var contrast = Self.plain
        contrast.increaseContrast = true

        #expect(contrast.borderWidth > Self.plain.borderWidth)
        #expect(Self.plain.tintsStateSymbol == true)
        #expect(contrast.tintsStateSymbol == false)
        #expect(Self.plain.dimsSecondaryText == true)
        #expect(contrast.dimsSecondaryText == false)
    }
}
