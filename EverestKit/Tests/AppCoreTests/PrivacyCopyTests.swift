import Testing

@testable import AppCore

/// The Privacy tab used to answer "where does your text go?" with "Nowhere."
/// That was false, and it was the one claim the whole app is sold on.
///
/// Everest writes the user's text to `NSPasteboard.general` in three places:
/// the synthetic ⌘C that reads a selection wherever Accessibility cannot
/// (every terminal, PDF and Google Doc), the ⌘V that writes the rewrite back,
/// and every copy-only outcome, which leaves the rewrite sitting there. The
/// general pasteboard is Handoff-eligible, so with Handoff on macOS may sync
/// any of it to the user's other devices for a couple of minutes.
///
/// There is no opt-out. The `org.nspasteboard.ConcealedType` and
/// `TransientType` markers already set are a convention clipboard-history
/// apps choose to honour; the OS ignores them. A private `NSPasteboard` would
/// not sync but also could not be pasted from, so it cannot do the job. The
/// claim is what gets fixed, not the behaviour.
///
/// Pinned here rather than left loose in a view for the reason
/// `OnboardingModel.exclusionCaveat` is: a privacy claim that drifts from
/// what the code does is the worst string in the app to get wrong.
@Test("the privacy copy admits the clipboard hop, names Handoff, and gives the remedy")
func thePrivacyCopyIsTrue() {
    let copy = PrivacyCopy.whereTextGoes

    // The exception has to be named, not implied.
    #expect(copy.localizedCaseInsensitiveContains("clipboard"))
    #expect(copy.localizedCaseInsensitiveContains("Handoff"))
    // Handoff is the only actual remedy, so say where it lives.
    #expect(copy.localizedCaseInsensitiveContains("System Settings"))
    // The strong half is true and stays stated plainly — that is what makes
    // the exception credible rather than an asterisk.
    #expect(copy.localizedCaseInsensitiveContains("server"))

    // And the two ways to get this wrong. "Nowhere" is the false absolute
    // this replaced; the text must not swing the other way either, because
    // the sync is to the user's own devices and not to a company.
    #expect(copy.localizedCaseInsensitiveContains("nowhere") == false)
    #expect(copy.localizedCaseInsensitiveContains("your own devices"))
}
