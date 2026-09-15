import Foundation

/// Says once, and only once, that Everest has taken a shortcut another app
/// already uses.
public struct ShortcutNotice {
    /// A shortcut reduced to the four things that decide a collision.
    ///
    /// `KeyboardShortcuts.Shortcut` is not used here because `AppCore` does
    /// not depend on that package — the recorder UI is app-target wiring, and
    /// the decision about what collides is not.
    public struct Shortcut: Equatable, Sendable {
        public let key: String
        public let command: Bool
        public let shift: Bool
        public let option: Bool
        public let control: Bool

        /// Whether this chord is a dead key on the **active keyboard
        /// layout** — measured by the app target with `UCKeyTranslate`, not
        /// inferred here. The same letter is dead on one layout and ordinary
        /// on another, so guessing from `key` would warn the wrong people
        /// and miss the right ones. Same split as rendering: the platform
        /// fact is measured where the layout is visible, and this module
        /// decides what to say about it.
        public let isDeadKey: Bool

        public init(
            key: String,
            command: Bool = false,
            shift: Bool = false,
            option: Bool = false,
            control: Bool = false,
            isDeadKey: Bool = false
        ) {
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
            self.isDeadKey = isDeadKey
        }

        /// Exactly `⌘I`, no other modifiers. `⌘⇧I` and `⌃⌘I` are not Italic in
        /// anything, so warning about them would be warning about nothing.
        var shadowsItalic: Bool {
            key.lowercased() == "i" && command && !shift && !option && !control
        }
    }

    private static let key = "everest.notice.italicShadowShown"
    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    /// The sentence to show, or `nil` when there is nothing to say.
    ///
    /// Two conditions, and both matter. Tied to the shortcut, because a user
    /// who has rebound to `⌥R` is being warned about a collision that no
    /// longer exists, which teaches them Everest's warnings are noise. Tied to
    /// having said it, because a warning that returns every launch gets
    /// dismissed unread — and so does the next one.
    /// Italic only, and deliberately not everything `caution` covers.
    ///
    /// `AppDelegate` builds this into an `NSAlert` titled "Everest uses ⌘I",
    /// which is correct by construction while this fires only for `⌘I` and a
    /// lie the moment it fires for anything else. A dead key belongs in the
    /// recorder's help text, where the user is looking at the box they just
    /// typed it into — not in a launch alert with the wrong headline.
    public func warning(for shortcut: Shortcut) -> String? {
        guard !store.bool(forKey: Self.key), shortcut.shadowsItalic else { return nil }
        return Self.italic
    }

    /// The same sentence with no once-gate, for the help text under the
    /// recorder.
    ///
    /// Two different jobs. The alert above interrupts a launch, so it must
    /// fire once or it gets dismissed unread. This describes the binding
    /// sitting in the box the user is looking at, so it has to be true every
    /// time they look — sharing the gate would blank the help text
    /// permanently after the first launch. The `⌘I` in the sentence is safe
    /// because `shadowsItalic` is exactly `⌘I`: whenever this returns a
    /// string, that is the binding.
    public static func caution(for shortcut: Shortcut) -> String? {
        // Dead key first: Italic is visible and reversible, this is neither.
        if shortcut.isDeadKey { return deadKey }
        if shortcut.shadowsItalic { return italic }
        return nil
    }

    private static let italic =
        "Everest uses ⌘I everywhere, which is Italic in most apps. Change it in Settings ▸ General if you would rather keep Italic."

    /// Says what breaks and where, because nothing else will.
    ///
    /// A Carbon global hotkey consumes the event, so binding a dead key
    /// takes the composition away in every app. The user who later cannot
    /// type `î` has no reason to suspect a shortcut they set here weeks ago,
    /// which is why the sentence names the accent rather than the mechanism.
    private static let deadKey =
        "This combination types an accent — macOS uses it to start characters like î, é, ü and ñ. While Everest holds it, those accents cannot be typed in any app. Pick a different key if you use them."


    public func markWarned() {
        store.set(true, forKey: Self.key)
    }
}
