import Overlay
import Testing
import TextBridge

@testable import AppCore

/// `ReplaceOutcome` has three cases, `CopyOnlyCause` has seven, and the panel
/// has three terminal states that can hold text. The compiler forces the
/// `switch` to be exhaustive; it cannot force the split to be the right one,
/// which is what this samples.
///
/// The two copy-only states differ only in the account they give: "the text
/// was not editable" versus "the original text had moved". Both tell the user
/// the rewrite is on the clipboard, so a wrong split is a wrong explanation,
/// never a lost rewrite — but an explanation the user can act on is the whole
/// reason there are two states instead of one.
@Test("every copy-only cause is sorted into the state that tells the user what to do")
func copyOnlyCausesSortIntoTheRightTerminalState() {
    // Retrying might genuinely work: the world moved, and it can move back.
    let moved: [CopyOnlyCause] = [.targetChanged, .secureField, .pasteNotConsumed]
    for cause in moved {
        #expect(
            PanelOutcome.state(for: .copiedOnly(cause: cause, reason: "why"), text: "rewritten")
                == .targetChanged(text: "rewritten"),
            "\(cause) should read as a target that moved"
        )
    }

    // Retrying will never work. `unverifiable` belongs here and not above: it
    // means the app never answered, which is the permanent and *correct*
    // state for everything captured through the clipboard — Terminal,
    // Ghostty, PDFs, ordinary web prose, the copy-only rows of root
    // `AGENTS.md` §3. Telling that user "the original text had moved" says
    // they did something and implies another go would help. Neither is true,
    // and they would keep trying.
    let nowhereToWrite: [CopyOnlyCause] = [.notEditable, .noAccessibility, .rangeDerived, .unverifiable]
    for cause in nowhereToWrite {
        #expect(
            PanelOutcome.state(for: .copiedOnly(cause: cause, reason: "why"), text: "rewritten")
                == .readOnly(text: "rewritten"),
            "\(cause) should read as a destination that takes no text"
        )
    }
}

/// The two outcomes that are not copy-only.
///
/// `heldForManualCopy` is the one that matters: nothing was written and
/// nothing was put on the clipboard, so the panel is holding the user's only
/// copy. It has to arrive carrying both the text and the reason, because
/// `PanelState.heldForManualCopy` is also the one state that never dismisses
/// itself, and a panel that held neither would be an empty box that will not
/// go away.
@Test("a written rewrite reports success; an unwritten, uncopied one arrives intact")
func writtenAndHeldOutcomesMapToTheirStates() {
    #expect(PanelOutcome.state(for: .replaced, text: "rewritten").kind == .success)

    #expect(
        PanelOutcome.state(
            for: .heldForManualCopy(cause: .clipboardBusy, reason: "another rewrite is using the clipboard"),
            text: "rewritten"
        ) == .heldForManualCopy(text: "rewritten", reason: "another rewrite is using the clipboard")
    )
}
