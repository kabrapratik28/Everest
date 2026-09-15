import Foundation
import TextBridge

/// A capture refusal, in words the user can act on.
///
/// One sentence per refusal, because each has a different remedy. Deliberately
/// not a count: this said "five" through the addition of a sixth, which is how
/// a comment stops being read. Resist folding them into "Everest could not read
/// your selection" — that sends the user looking in the wrong place almost
/// every time: granting a permission they already granted, hunting for a
/// selection they did make, shortening text that was never too long.
///
/// The secure-field sentence earns its second clause specifically. That refusal
/// is the app working exactly as designed, and without being told so the user
/// reads a failure and tries again somewhere less safe.
public enum CaptureFailure {
    /// Takes `any Error` rather than `CaptureError` so the coordinator's catch
    /// has no second branch. `SelectionCoordinator.capture()` is declared with
    /// untyped `throws`, so the compiler cannot prove `CaptureError` is all it
    /// can produce; putting the fallback here keeps the one unprovable case in
    /// the tested lookup instead of in an untested `else` beside the panel call.
    public static func message(for error: any Error) -> String {
        guard let error = error as? CaptureError else {
            return "Everest could not read the selection. Try again, or select the text in a different app."
        }
        return switch error {
        case .accessibilityNotGranted:
            // The second sentence exists because of a real bug report. TCC
            // binds this permission to the code signature, so after the app is
            // replaced the switch stays on while pointing at a signature that
            // no longer exists. Telling that user to "switch Everest on" sends
            // them to do the thing they can see they already did.
            "Everest needs Accessibility permission to read your selection. Open System Settings ▸ Privacy & Security ▸ Accessibility and switch Everest on. If it is already on, remove Everest from that list with the − button and add it again — the permission goes stale when the app is updated."
        case .secureField:
            // Says the refusal *is* the app working, without the absolute
            // that `OnboardingModel.passwordPromise` had to lose: "never
            // reads passwords" is a guarantee the chain cannot make for an
            // app exposing no accessibility tree. What is true here is what
            // this sentence now claims — this field was recognised, and
            // nothing was read.
            "That is a secure field, so nothing was read. Everest refuses these before looking at them."
        case .noSelection:
            "Select the text you want rewritten, then press the shortcut again."
        case .nothingCaptured:
            // Reads as two remedies because the capture chain genuinely could
            // not tell which one applies, and guessing costs the user more
            // than saying so. Offering only "select some text" to somebody
            // looking at their own highlighted paragraph sends them to
            // reselect and press again, indefinitely, learning nothing.
            "Everest tried every way it has to read this app — Accessibility, then a copy — and got nothing back. If your text is selected, this app draws it somewhere macOS cannot read it; Google Docs works that way. If it is not selected, select it and press the shortcut again."
        case .clipboardUnavailable:
            // Names the clipboard rather than the app. The refusal itself is
            // correct and protective — the borrow is declined before ⌘C is
            // posted, so nothing is destroyed — but reporting it as an
            // unreadable app sends someone with a screenshot on their
            // clipboard looking for a Google Docs permission that does not
            // exist. The remedy is "copy something small", not "clear the
            // clipboard": macOS offers no way to empty it, so the only thing
            // the user can actually do is replace what is on it.
            "Everest reads some apps by copying, and it will not do that while your clipboard holds something too large to put back — a screenshot or an image, usually. Copy a word of text to replace it, then press the shortcut again."
        case let .tooLong(count):
            "That selection is \(grouped(count)) characters. Everest rewrites up to \(grouped(CaptureLimits.maxCharacters)) at a time — select a shorter passage."
        case let .excludedApp(bundleID):
            "Everest is set to stay out of \(bundleID). Remove it from the excluded apps in Settings ▸ Privacy to rewrite here."
        }
    }

    /// The cap is read from `CaptureLimits` rather than written out, so the
    /// sentence cannot drift from the limit it is describing.
    private static func grouped(_ count: Int) -> String {
        count.formatted(.number)
    }
}
