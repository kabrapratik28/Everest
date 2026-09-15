import ApplicationServices
import Testing

@testable import TextBridge

/// Three independent reasons the captured text is never trimmed, normalised
/// or cleaned, any one of which is sufficient:
///
/// 1. It changes what the user selected. Leading and trailing whitespace is
///    often exactly what makes a rewrite fit back into the sentence around it.
/// 2. It breaks replacement. `TargetValidator` compares the snapshot text
///    against the live selection character for character, so a trimmed capture
///    never matches and the rewrite silently never gets written back anywhere.
/// 3. It papers over the Chromium off-by-one instead of fixing it. That is a
///    *range*-level problem; trimming a stray leading space hides the symptom
///    in the one case where the shifted character is whitespace and destroys
///    legitimate whitespace in every other case.
@Suite("Text fidelity")
struct TextFidelityTests {

    @Test("whitespace, tabs and newlines survive every capture route byte for byte",
          arguments: CaptureRoute.allCases)
    func textSurvivesByteForByte(route: CaptureRoute) throws {
        let original = "  spaced  \tand\ttabbed  \n\n  and a trailing newline\n"

        let snapshot = try captureText(original, via: route)

        #expect(snapshot.text == original)
        #expect(Array(snapshot.text.utf8) == Array(original.utf8))
    }

    /// Composed characters, combining marks and a zero-width joiner sequence.
    /// Any normalisation pass would quietly rewrite these.
    @Test("composed and combining characters are not normalised",
          arguments: CaptureRoute.allCases)
    func unicodeIsNotNormalised(route: CaptureRoute) throws {
        let original = "e\u{0301}clair \u{1F469}\u{200D}\u{1F4BB} \u{FF41}\u{0000}end"

        let snapshot = try captureText(original, via: route)

        #expect(Array(snapshot.text.unicodeScalars) == Array(original.unicodeScalars))
    }
}
