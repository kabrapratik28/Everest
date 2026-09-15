import AppCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// `⌥R` — two keys, chosen after ruling out the other two families.
    ///
    /// A global hotkey beats the frontmost app, so the default is really a
    /// question of *what Everest is willing to take away from every app on the
    /// machine*.
    ///
    /// - **`⌘`+letter is out.** Every letter is a formatting or editing
    ///   command somewhere: `⌘I` Italic, `⌘U` Underline, `⌘B` Bold, `⌘K` link.
    ///   `⌘⇧I` is Web Inspector in three browsers.
    /// - **`⌃`+letter is out, and worst of the three.** Cocoa text views carry
    ///   emacs bindings (`⌃A` `⌃E` `⌃K` `⌃D` `⌃N` `⌃P` `⌃T` `⌃Y` `⌃W`) and
    ///   terminals own `⌃C` `⌃D` `⌃Z` `⌃L` `⌃R` `⌃U`. Terminals are a
    ///   first-class target here, so this family collides where it hurts most.
    /// - **`⌥`+letter costs one character**, and that is the cheapest price
    ///   available. `⌥R` is `®`.
    ///
    /// **Not `⌥I`, `⌥E`, `⌥U` or `⌥N`** — those are *dead keys*. They swallow
    /// the next keystroke to compose `î é ü ñ`, so binding one globally breaks
    /// accented typing outright, which is worse than shadowing a command. That
    /// is what cost us the obvious mnemonic, I for Improve.
    ///
    /// `R` for Rewrite is the mnemonic that survived the elimination.
    static let quickImprove = Self("quickImprove", default: .init(.r, modifiers: [.option]))

    /// `⌥⇧R`. Deliberately the Quick Improve chord plus Shift, so the pair is
    /// one thing to remember rather than two.
    static let chooseStyle = Self("chooseStyle", default: .init(.r, modifiers: [.option, .shift]))
}

/// Registration, and nothing else.
///
/// `KeyboardShortcuts` wraps Carbon's `RegisterEventHotKey`, which is why
/// Everest needs no Input Monitoring permission on top of Accessibility. It
/// also persists and restores the user's own bindings, so there is nothing
/// here that reads or writes them.
@MainActor
final class HotkeyManager {
    private let coordinator: RewriteCoordinator

    init(coordinator: RewriteCoordinator) {
        self.coordinator = coordinator
    }

    func register() {
        // `onKeyDown`, so the panel appears while the user is still holding
        // the chord rather than after they let go.
        //
        // The coordinator is an actor and these handlers are synchronous, so
        // each press starts a task and returns. That is also what makes a
        // second press able to supersede the first: it is not queued behind
        // the generation it is replacing.
        KeyboardShortcuts.onKeyDown(for: .quickImprove) { [coordinator] in
            Task { await coordinator.quickImprove() }
        }
        KeyboardShortcuts.onKeyDown(for: .chooseStyle) { [coordinator] in
            Task { await coordinator.chooseStyle() }
        }
    }

    /// The Quick Improve binding, reduced to what `ShortcutNotice` needs to
    /// decide whether it collides with Italic.
    ///
    /// The collision rule itself is in `AppCore`, where it has a test. This is
    /// only the translation out of `KeyboardShortcuts.Shortcut`.
    static var quickImproveShortcut: ShortcutNotice.Shortcut? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .quickImprove) else { return nil }
        return ShortcutNotice.Shortcut(
            key: shortcut.key == .i ? "i" : "",
            command: shortcut.modifiers.contains(.command),
            shift: shortcut.modifiers.contains(.shift),
            option: shortcut.modifiers.contains(.option),
            control: shortcut.modifiers.contains(.control)
        )
    }

    /// What a binding currently looks like, for the status-item menu.
    ///
    /// Rendered by `KeyboardShortcuts` and not re-implemented in `AppCore`,
    /// deliberately. Turning a key code into a character needs the active
    /// keyboard layout — `UCKeyTranslate`, so the same code is `I` on QWERTY
    /// and something else on AZERTY — which `AppCore` cannot do and should not
    /// pretend to. It is also the exact string the recorder in Settings ▸
    /// General shows, so the menu and the recorder cannot disagree about the
    /// same binding. `nil` when the user has cleared it, and the menu then
    /// shows nothing rather than a default that is not in force.
    ///
    /// `Hotkey` is `AppCore`'s, and this switch is exhaustive over it: adding
    /// a hotkey there fails to compile here rather than quietly producing a
    /// menu item that never gets a label.
    static func rendered(_ hotkey: Hotkey) -> String? {
        let name: KeyboardShortcuts.Name = switch hotkey {
        case .quickImprove: .quickImprove
        case .chooseStyle: .chooseStyle
        }
        return KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
