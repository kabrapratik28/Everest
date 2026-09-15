import Overlay
import TextBridge

/// Turns a `ReplaceOutcome` into the terminal state that describes it.
///
/// Seven copy-only causes, two panel states that can hold text and say where
/// it went. The split is by *what the user should do next*, not by how the
/// write failed: `targetChanged` says "your document is not where you left it,
/// look before you paste", `readOnly` says "this place does not take text,
/// paste it somewhere else". Both are honest that the rewrite is on the
/// clipboard, which is the part that matters.
///
/// The `switch` has no `default` on purpose. A new `CopyOnlyCause` in
/// `TextBridge` must be a compile error here, not a silent fall into whichever
/// side happened to be the fallback.
public enum PanelOutcome {
    public static func state(for outcome: ReplaceOutcome, text: String) -> PanelState {
        switch outcome {
        case .replaced:
            .success

        case let .copiedOnly(cause, _):
            switch cause {
            // The world moved, and it can move back, so another go might
            // work: another app came to the front, focus went elsewhere, a
            // password field took over, or the target took a paste and did
            // nothing with it. "Check before you paste" is the advice.
            case .targetChanged, .secureField, .pasteNotConsumed:
                .targetChanged(text: text)

            // There is nowhere to write, and trying again will not change
            // that: no editable buffer, no permission, a range-derived
            // capture we will not write back, or an app that never answered.
            //
            // `unverifiable` is here and not above. It is the permanent and
            // *correct* state for everything captured through the clipboard —
            // Terminal, Ghostty, PDFs, ordinary web prose, the copy-only rows
            // of root `AGENTS.md` §3 — which are working as designed rather
            // than failing. "The original text had moved" would tell that user
            // they did something and imply a retry helps. It never will, and
            // they would keep trying.
            case .notEditable, .noAccessibility, .rangeDerived, .unverifiable:
                .readOnly(text: text)
            }

        // Neither written nor copied, so the panel holds the only copy of the
        // user's rewrite. Both the text and the reason travel with it, and
        // `PanelState.autoDismissAfter` is `nil` for this state alone.
        case let .heldForManualCopy(_, reason):
            .heldForManualCopy(text: text, reason: reason)
        }
    }
}
