/// What the Privacy tab says about where the user's text goes.
///
/// Here, with a test, for the reason `OnboardingModel.exclusionCaveat` is: a
/// privacy claim that drifts from what the code actually does is the worst
/// string in this app to get wrong, and a view is where nobody checks it.
///
/// It said "Nowhere." That was false. Everest writes the selection or the
/// rewrite to `NSPasteboard.general` three times — the synthetic ⌘C that
/// reads a selection wherever Accessibility cannot, the ⌘V that writes it
/// back, and every copy-only outcome — and the general pasteboard is
/// Handoff-eligible.
///
/// **There is no opt-out, so the claim changed and the behaviour did not.**
/// The `org.nspasteboard.ConcealedType` and `TransientType` markers in
/// `PasteboardTransaction` are a convention clipboard-history apps choose to
/// honour; the OS ignores them for sync. A private `NSPasteboard` would not
/// sync, but nothing else could paste from it, so it cannot do the job —
/// which would cost terminals, PDFs and Google Docs entirely.
public enum PrivacyCopy {
    /// Stated plainly rather than as a footnote. A privacy claim with an
    /// asterisk is worse than a smaller claim told straight, and the strong
    /// half here is true and worth keeping loud: the model is local and
    /// nothing reaches a server. Equally it must not overstate — the sync is
    /// to the user's own devices, encrypted, for about two minutes, and only
    /// with Handoff on. "Your text is sent to Apple" would be its own lie.
    public static let whereTextGoes = """
        Everest runs the model on this Mac. No selection, no rewrite and no telemetry is sent \
        to any server, and the app works with networking switched off.

        The clipboard is the one exception. Where macOS will not hand over a selection — \
        terminals, PDFs, Google Docs — Everest copies it, and it pastes rewrites back the same \
        way. Anything on the clipboard is eligible for Handoff, so with Handoff on, macOS may \
        sync it to your own devices for a couple of minutes. That is between your devices and \
        encrypted, and no app can opt out of it. Turn Handoff off in System Settings ▸ General \
        if you would rather it did not happen.
        """
}
