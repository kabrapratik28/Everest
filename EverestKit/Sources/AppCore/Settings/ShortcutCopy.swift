import Foundation

/// Sentences that name a keyboard shortcut.
///
/// Here rather than in the views because a shortcut in prose is a copy of the
/// binding, and copies go stale. This one already did: the defaults moved from
/// `⌘I` to `⌃⌥I` and then again to `⌥R`, and onboarding, the Settings help
/// text, the README and several comments went on saying `⌘I` — so a new user
/// followed the setup guide, pressed a key that did nothing, and concluded the
/// app was broken. A fixed collision became a broken first run.
///
/// The rule that came out of it: **nothing ever hardcodes a glyph.** Every
/// displayed shortcut is rendered from the live `KeyboardShortcuts` value at
/// the moment it is shown. The app target does the rendering, because turning
/// a key code into a character needs the active keyboard layout; this decides
/// what the sentence around it says, including when there is nothing to name.
public enum ShortcutCopy {
    /// The try-it step's instruction, naming whatever is bound right now.
    ///
    /// `nil` means the user has cleared the recorder. Interpolating that
    /// leaves "press ." on the one screen whose whole job is teaching the
    /// shortcut, and substituting the default glyph would name a key that does
    /// nothing — so the sentence changes shape instead and says where to set
    /// one.
    public static func tryItInstruction(quickImprove rendered: String?) -> String {
        guard let rendered else {
            return """
                No Quick Improve shortcut is set. Record one in Settings ▸ General, then come \
                back and try it here.
                """
        }
        // The load note belongs here and not on the unbound branch: with no
        // shortcut set there is no rewrite to wait for, and that branch's
        // whole job is sending the user to Settings.
        return """
            Type something below, select it, and press \(rendered). The panel appears at the \
            bottom of the screen and the rewrite replaces what you selected.

            The first rewrite is slow. The model is loaded into memory before it can start, \
            which takes a few seconds, and nothing moves while it does. It stays loaded \
            afterwards, so every rewrite after the first is quick.
            """
    }
}
