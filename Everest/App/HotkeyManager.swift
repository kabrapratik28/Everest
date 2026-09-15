import AppCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// `⌘I`. Shadows Italic almost everywhere; accepted, and warned about
    /// once — see `ShortcutNotice`.
    /// `⌃⌥I`, not `⌘I`.
    ///
    /// `⌘I` was the originally requested default and it is a bad one: a global
    /// hotkey wins over the frontmost app, so while Everest runs it takes
    /// Italic away from every editor and Get Info from Finder. `⌘⇧I` is no
    /// better — it is Web Inspector in Chrome, Safari and Firefox.
    ///
    /// Control+Option is the one modifier pair macOS and mainstream apps leave
    /// almost entirely alone, so it collides with nothing common. Both remain
    /// user-editable in Settings, and `⌘I` is still accepted if asked for; the
    /// recorder warns once via `ShortcutNotice`.
    static let quickImprove = Self("quickImprove", default: .init(.i, modifiers: [.control, .option]))

    /// `⌘⇧I`. Shift keeps it clear of Italic.
    /// `⌃⌥⇧I`. Same reasoning, and deliberately the Quick Improve chord plus
    /// Shift so the pair is one thing to remember rather than two.
    static let chooseStyle = Self(
        "chooseStyle", default: .init(.i, modifiers: [.control, .option, .shift]))
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
}
