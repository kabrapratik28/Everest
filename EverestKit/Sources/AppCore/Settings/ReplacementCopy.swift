/// What the replacement settings say about themselves.
///
/// Pinned with a test for the reason `PrivacyCopy` and
/// `OnboardingModel.exclusionCaveat` are: these are claims about what happens
/// to the user's text, made on the screen where they decide how much to trust
/// the app, and a claim the code cannot keep is worse than a smaller one. The
/// Privacy screen said text goes "Nowhere" and that was false; this is the
/// same trap with a different mechanism.
public enum ReplacementCopy {
    /// Under "Replace automatically".
    ///
    /// Says what **off** does, because the label does not. "Replace
    /// automatically" reads as replace-versus-do-not, which is not the
    /// choice on offer: Everest replaces either way. The switch decides
    /// whether it posts the paste itself or hands over the clipboard and
    /// says so, and naming the clipboard is the only thing that makes the
    /// off state legible.
    ///
    /// "Where it can" is doing real work and must not become "always".
    /// Auto-replace is only reached once writing in place has already
    /// failed, and it is declined even then for targets that are an
    /// application-level clipboard snapshot rather than a focused element —
    /// a terminal or a PDF, where a posted ⌘V would land in a shell prompt.
    public static let autoReplaceExplanation = """
        Where Everest cannot write into the app directly, it pastes the rewrite for you. \
        Switch this off and it puts the rewrite on your clipboard instead and tells you to \
        paste it yourself.
        """

    /// Under "Keep rewrites out of clipboard history".
    ///
    /// The honour-system part is not a detail to soften. Everest marks the
    /// write `org.nspasteboard.TransientType`, which Maccy, Alfred and
    /// Raycast choose to respect — macOS neither enforces it nor knows about
    /// it. A manager that ignores it records the rewrite, and the toggle
    /// cannot stop it. Saying so is what makes the rest of the sentence worth
    /// believing.
    ///
    /// It also avoids implying the rewrite skips the clipboard. It does not,
    /// and usually cannot: the clipboard *is* how a rewrite reaches an app
    /// Accessibility cannot write to. This is about what records it, not
    /// about where it goes — see `PrivacyCopy.whereTextGoes` for that.
    public static let historyCaveat = """
        Everest marks each rewrite so clipboard managers skip it, and Maccy, Alfred and Raycast \
        all honour that marker. It is a convention between apps rather than a macOS rule, so a \
        manager that ignores it will still record the text.
        """

    /// The consequence of having both switches on, or `nil` when it does not
    /// apply.
    ///
    /// Auto-replace posts the paste and the clipboard is then restored to
    /// whatever the user had; history off means nothing recorded it either.
    /// So the rewrite exists only in their document. That is correct, and it
    /// is still a change from behaviour where they always had a copy to
    /// re-paste — which is why it is said out loud rather than discovered.
    ///
    /// Conditional on purpose. Shown against the other three combinations it
    /// would be warning about nothing: the text is either still sitting on
    /// the clipboard for them to paste, or in their manager's history. A
    /// caution that fires when nothing is at stake is one people learn to
    /// skip, and then it is not there for the case that matters.
    public static func retrievalNote(autoReplace: Bool, keepOutOfHistory: Bool) -> String? {
        guard autoReplace, keepOutOfHistory else { return nil }
        return """
            With both of these on, a rewrite is not kept anywhere once it lands: your clipboard \
            goes back to what it held, and nothing reaches clipboard history. The copy in your \
            document is the only one.
            """
    }
}
