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

        public init(
            key: String,
            command: Bool = false,
            shift: Bool = false,
            option: Bool = false,
            control: Bool = false
        ) {
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
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
    public func warning(for shortcut: Shortcut) -> String? {
        guard shortcut.shadowsItalic else { return nil }
        guard !store.bool(forKey: Self.key) else { return nil }
        return "Everest uses ⌘I everywhere, which is Italic in most apps. Change it in Settings ▸ General if you would rather keep Italic."
    }

    public func markWarned() {
        store.set(true, forKey: Self.key)
    }
}
