import Foundation
import RewriteCore
import Testing

@testable import AppCore

/// The clipboard-history toggle is the easiest control in the app to
/// overclaim, so its caveat is pinned the way `PrivacyCopy` is.
///
/// `org.nspasteboard.TransientType` is a **convention**. Maccy, Alfred and
/// Raycast choose to honour it; macOS does not enforce it and cannot. A
/// manager that ignores it records the rewrite anyway, and a toggle that
/// promised otherwise would be the Privacy screen's "Nowhere." again — a
/// claim the code cannot keep, on the screen where the user is deciding how
/// much to trust us.
@Test("the clipboard-history caveat says the marker is a convention, not a guarantee")
func theHistoryCaveatDoesNotOverclaim() {
    let caveat = ReplacementCopy.historyCaveat

    // It has to name the mechanism as something apps opt into.
    #expect(caveat.localizedCaseInsensitiveContains("convention"))
    // And admit the failure mode rather than implying there is none.
    #expect(caveat.localizedCaseInsensitiveContains("ignore"))
}

/// A toggle has to say what turning it **off** does, or nobody can tell what
/// they are switching away from.
///
/// "Replace automatically" reads as "replace text" versus "do not", which is
/// not the choice. Everest replaces either way; the switch decides whether it
/// posts the paste for you or hands you the clipboard and says so. Naming the
/// clipboard is what makes the off state legible.
///
/// It must also not promise pasting everywhere. Auto-replace only reaches the
/// cases where writing in place already failed, and not even all of those.
@Test("the auto-replace explanation names what happens when it is off")
func theAutoReplaceExplanationNamesTheOffState() {
    let explanation = ReplacementCopy.autoReplaceExplanation

    #expect(explanation.localizedCaseInsensitiveContains("clipboard"))
    // No unqualified promise: "always" or "every" here would be a claim the
    // refusal cases break.
    #expect(explanation.localizedCaseInsensitiveContains("always") == false)
}

/// The one combination that leaves the rewrite nowhere but the document has
/// to say so, and the other three must not.
///
/// With auto-replace on, the paste is posted for the user and the clipboard
/// is restored to whatever they had; with history off, nothing records it
/// either. That is correct — the text is in their document — but it is a
/// change from today, and someone who expected to re-paste reads it as data
/// loss. Warning on the other three would be worse than not warning at all:
/// a caution that fires when nothing is at stake is one people learn to skip,
/// and then it is not there when it matters.
@Test("the retrieval warning appears only when both settings remove every other copy")
func theRetrievalWarningIsConditional() {
    let warned = ReplacementCopy.retrievalNote(autoReplace: true, keepOutOfHistory: true)

    #expect(warned != nil)
    // The reassurance is the load-bearing half: the text is not lost, it is
    // in the document. Without that this reads as a bug report.
    #expect(warned?.localizedCaseInsensitiveContains("document") == true)

    // Still on the clipboard for the user to paste.
    #expect(ReplacementCopy.retrievalNote(autoReplace: false, keepOutOfHistory: true) == nil)
    // Recorded by whichever manager they run.
    #expect(ReplacementCopy.retrievalNote(autoReplace: true, keepOutOfHistory: false) == nil)
    #expect(ReplacementCopy.retrievalNote(autoReplace: false, keepOutOfHistory: false) == nil)
}

/// Both settings default **on**, and a `UserDefaults` bool cannot express
/// that by itself.
///
/// `store.bool(forKey:)` returns `false` for a key that was never written, so
/// the obvious implementation ships both switches off and every user has to
/// find and enable the behaviour we decided should be the default. The
/// absence of a value and a stored `false` have to be told apart, and the
/// only thing that does it is `object(forKey:)`.
///
/// The second half matters as much: once turned off, off must survive a
/// relaunch. An implementation that defaults on by ignoring a stored `false`
/// passes the first assertion and silently re-enables itself forever.
///
/// Tested from here rather than `RewriteCoreTests`: the carve-out I was given
/// is `Settings.swift` alone, and these are the defaults my screens render.
@Test("auto-replace and history-exclusion default on, and stay off once turned off")
@MainActor
func theReplacementSettingsDefaultOn() {
    let suite = "com.kabrapratik.Everest.replacement.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!

    let fresh = AppSettings(store: store)
    #expect(fresh.replacesAutomatically)
    #expect(fresh.keepsOutOfClipboardHistory)

    fresh.replacesAutomatically = false
    fresh.keepsOutOfClipboardHistory = false

    // A later launch reads the same store and must not re-enable them.
    let relaunched = AppSettings(store: store)
    #expect(relaunched.replacesAutomatically == false)
    #expect(relaunched.keepsOutOfClipboardHistory == false)
}
