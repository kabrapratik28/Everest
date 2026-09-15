import Foundation
import Testing

@testable import AppCore

/// Every screen that names a shortcut has to name the one that is bound now.
///
/// This has already gone wrong once. The defaults moved from `⌘I` / `⌘⇧I` to
/// `⌃⌥I` / `⌃⌥⇧I` and every instruction screen kept saying `⌘I`, so a new
/// user followed onboarding, pressed `⌘I`, and nothing happened — a fixed
/// collision turned into a broken setup flow. Users can also re-record both
/// bindings at any time, so a correct literal is only correct until they do.
@Test("the try-it instruction names the shortcut that is actually bound")
func theInstructionNamesTheLiveShortcut() {
    let bound = ShortcutCopy.tryItInstruction(quickImprove: "⌃⌥I")

    #expect(bound.contains("⌃⌥I"))
    // Not the old default, and not any other literal: whatever is passed in.
    #expect(ShortcutCopy.tryItInstruction(quickImprove: "⌥R").contains("⌥R"))
    #expect(ShortcutCopy.tryItInstruction(quickImprove: "⌥R").contains("⌃⌥I") == false)
}

/// A user who cleared the binding gets told to set one, not a sentence with a
/// hole in it.
///
/// `KeyboardShortcuts.getShortcut(for:)` returns `nil` once the recorder is
/// cleared. Interpolating that leaves "press ." on the one screen whose whole
/// job is teaching the shortcut, and falling back to the default glyph would
/// name a key that does nothing.
@Test("with no shortcut bound the instruction says where to set one")
func theInstructionHandlesAnUnboundShortcut() {
    let unbound = ShortcutCopy.tryItInstruction(quickImprove: nil)

    #expect(unbound.contains("Settings"))
    #expect(unbound.contains("⌘") == false)
    #expect(unbound.contains("press .") == false)
}

/// The Italic caution has to keep appearing next to the recorder for as long
/// as the binding actually collides.
///
/// `warning(for:)` is the launch alert and is deliberately once-only — a
/// warning that returns every launch gets dismissed unread. The help text
/// under the recorder is the opposite: it describes the binding currently in
/// the box, so it has to be true every time that box is looked at, including
/// after the alert has been dismissed. Sharing the once-gate would make the
/// help text disappear permanently the first time the app launched.
@Test("the help text keeps saying a shortcut collides after the launch alert has been dismissed")
func theCautionIsNotSilencedByTheOnceGate() {
    let store = UserDefaults(suiteName: "com.kabrapratik.Everest.caution.\(UUID().uuidString)")!
    let italic = ShortcutNotice.Shortcut(key: "i", command: true)
    let notice = ShortcutNotice(store: store)

    #expect(notice.warning(for: italic) != nil)
    notice.markWarned()
    #expect(notice.warning(for: italic) == nil, "the alert is once-only")

    // The help text is not.
    #expect(ShortcutNotice.caution(for: italic) != nil)
    // And it still says nothing about a binding that collides with nothing —
    // ⌃⌥I, the current default, is Italic in no app.
    #expect(ShortcutNotice.caution(for: .init(key: "i", option: true, control: true)) == nil)
}
