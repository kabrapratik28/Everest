import Foundation
import Testing

@testable import AppCore

/// Every screen that names a shortcut has to name the one that is bound now.
///
/// This has already gone wrong. The default moved from `⌘I` to `⌃⌥I` and
/// then again to `⌥R`, while every instruction screen kept saying `⌘I`, so a
/// new user followed onboarding, pressed `⌘I`, and nothing happened — a fixed
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
    // ⌃⌥I is Italic in no app, so it earns no caution on that ground.
    #expect(ShortcutNotice.caution(for: .init(key: "i", option: true, control: true)) == nil)
}

/// A dead-key binding breaks accented typing, silently, and the recorder is
/// the only place it can be caught.
///
/// `⌥I`, `⌥E`, `⌥U`, `⌥N` and `⌥\`` compose `î é ü ñ ǹ` by swallowing the
/// next keystroke. A Carbon global hotkey *consumes* the event, so binding
/// one takes the composition away everywhere — and the user has no reason to
/// connect "I can no longer type î" to a shortcut they set in a rewriting
/// app weeks ago. That is what cost this project the I-for-Improve mnemonic.
///
/// **Whether a chord is dead is a property of the active keyboard layout**,
/// not of the letter: the same key is dead on a US layout and ordinary on
/// others. So `AppCore` does not guess it — the app target measures it with
/// `UCKeyTranslate` and passes the answer in, exactly as it does for
/// rendering. This decides only what to say about it.
///
/// Ordered ahead of the Italic caution because it is the worse failure:
/// Italic is visible and reversible, a dead key is neither.
@Test("a dead-key binding is cautioned about, ahead of a merely inconvenient one")
func aDeadKeyBindingIsCautioned() {
    let dead = ShortcutNotice.Shortcut(key: "i", option: true, isDeadKey: true)
    let caution = ShortcutNotice.caution(for: dead)

    #expect(caution != nil)
    #expect(caution?.localizedCaseInsensitiveContains("accent") == true)

    // The same chord measured as ordinary on this layout says nothing.
    #expect(ShortcutNotice.caution(for: .init(key: "i", option: true)) == nil)
}

/// The launch alert stays Italic-only, and must not inherit the dead-key
/// caution.
///
/// `warnAboutItalicOnce` builds an `NSAlert` whose title is literally
/// "Everest uses ⌘I" — correct by construction while `warning` fires only
/// for `⌘I`, and a lie the moment it fires for `⌥I`. The recorder's help
/// text is where a dead key belongs: the user is looking at the box they
/// just typed it into.
@Test("the launch alert does not fire for a dead key, whose title would be wrong")
func theLaunchAlertStaysItalicOnly() {
    let store = UserDefaults(suiteName: "com.kabrapratik.Everest.deadkey.\(UUID().uuidString)")!
    let notice = ShortcutNotice(store: store)

    #expect(notice.warning(for: .init(key: "i", option: true, isDeadKey: true)) == nil)
    // Positive control: the alert still fires for the case it is titled for.
    #expect(notice.warning(for: .init(key: "i", command: true)) != nil)
}

/// Every printable binding costs the user a character, and the recorder is
/// where they should learn which one.
///
/// A Carbon global hotkey consumes the event, so while Everest runs `⌥R` no
/// longer types `®` anywhere. That is true of any printable combination —
/// `⌥J` costs `∆`, `⌥W` costs `∑` — so the useful thing is not to document
/// `®` but to name whatever *this* binding costs.
///
/// **Information, not a caution.** `⌥R` is the recommended default and this
/// cost is precisely why it was chosen over `⌘I`; styling it like the Italic
/// warning would read as "you have done something wrong", and a warning that
/// fires on the default is one people learn to skip. So it is a separate
/// call from `caution` rather than another case inside it.
@Test("a printable binding says which character it costs")
func aPrintableBindingNamesItsCost() {
    let note = ShortcutNotice.characterCost(for: "®")

    #expect(note?.contains("®") == true)
    // Not phrased as a problem: no "warning", no "instead", nothing to fix.
    #expect(note?.localizedCaseInsensitiveContains("warning") == false)
}

/// Nothing to say when the chord produces nothing.
///
/// A function key, an arrow, a dead key — none of them cost a character the
/// user could otherwise type. `nil` means the recorder shows no extra line at
/// all, which is the common case and must stay silent: a note under every
/// binding is noise, and noise is what teaches people to stop reading the
/// one that matters.
@Test("a binding that produces no character says nothing")
func aNonPrintingBindingSaysNothing() {
    #expect(ShortcutNotice.characterCost(for: nil) == nil)
    #expect(ShortcutNotice.characterCost(for: "") == nil)
}
