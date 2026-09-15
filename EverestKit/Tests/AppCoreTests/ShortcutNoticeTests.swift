import Foundation
import Testing

@testable import AppCore

private func makeStore() -> UserDefaults {
    UserDefaults(suiteName: "com.kabrapratik.Everest.notice.\(UUID().uuidString)")!
}

/// `⌘I` is Italic in almost every app that has formatting, and Everest takes
/// it globally. That is the accepted default — it is the shortcut people
/// reach for — but taking it silently means the first time someone tries to
/// italicise a word in Mail they get a rewrite panel and no explanation.
///
/// Tied to the shortcut rather than shown unconditionally: a user who has
/// already rebound to `⌥R` is being warned about a collision that does not
/// exist, which teaches them the app's warnings are noise.
@Test("the Italic collision is reported only for the shortcut that actually collides")
func onlyTheCollidingShortcutIsReported() {
    let notice = ShortcutNotice(store: makeStore())

    #expect(notice.warning(for: .init(key: "i", command: true)) != nil)
    // The style picker's default. Shift is Italic-free.
    #expect(notice.warning(for: .init(key: "i", command: true, shift: true)) == nil)
    // Rebound away from the collision.
    #expect(notice.warning(for: .init(key: "r", command: false, option: true)) == nil)
    // ⌃⌘I is not Italic either.
    #expect(notice.warning(for: .init(key: "i", command: true, control: true)) == nil)
}

/// Once, and once means across relaunches.
///
/// A warning that returns every launch is one the user learns to dismiss
/// without reading, which is worse than not warning: the next warning Everest
/// shows will be dismissed the same way.
@Test("the collision is mentioned once, and stays mentioned across relaunches")
func theWarningIsGivenOnce() {
    let store = makeStore()
    let shortcut = ShortcutNotice.Shortcut(key: "i", command: true)

    let first = ShortcutNotice(store: store)
    #expect(first.warning(for: shortcut) != nil)
    first.markWarned()
    #expect(first.warning(for: shortcut) == nil)

    // A fresh launch reads the same store.
    #expect(ShortcutNotice(store: store).warning(for: shortcut) == nil)
}
