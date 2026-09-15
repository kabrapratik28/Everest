import AppKit
import Foundation

/// Rung 9: borrow the clipboard, make the target app copy into it, read it,
/// give it back.
///
/// **The leak is unavoidable and you should know about it.** During the
/// synthetic ⌘C the *target app* writes the selected text to the pasteboard.
/// That write is not ours, so we cannot mark it transient, and any clipboard
/// history app the user runs will record it. Restoring immediately afterwards
/// limits the exposure to a few hundred milliseconds, but a history app
/// watching the pasteboard will have caught it. That is a real argument for
/// keeping the accessibility paths healthy rather than letting apps drift
/// onto this one.
///
/// **The waits block the main thread and must not pump the run loop.**
/// Pumping from inside a hotkey handler would let a second hotkey press
/// re-enter the capture chain while the first is halfway through borrowing
/// the clipboard. Blocking is the lesser problem, and only on the path that
/// accessibility-hostile apps reach.
public final class ClipboardSelectionAdapter: ClipboardCapturing {
    private let pasteboard: NSPasteboard
    private let keystroke: KeystrokeCopying
    private let borrow: PasteboardBorrow

    /// Bounded, never fixed. A fast app costs about one poll and returns the
    /// instant it has an answer.
    private let copyBudget: Duration
    private let settleBudget: Duration
    private let pollInterval: Duration

    public init(
        pasteboard: NSPasteboard,
        keystroke: KeystrokeCopying,
        borrow: PasteboardBorrow = .shared,
        copyBudget: Duration = .milliseconds(400),
        settleBudget: Duration = .milliseconds(120),
        pollInterval: Duration = .milliseconds(8)
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.borrow = borrow
        self.copyBudget = copyBudget
        self.settleBudget = settleBudget
        self.pollInterval = pollInterval
    }

    public func copySelection(pid: pid_t) -> String? {
        let transaction = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)

        // Before posting, not after: that keystroke makes the *target app*
        // overwrite the clipboard, and if we could not take a faithful copy
        // we would be unable to put it back.
        guard transaction.snapshot() else { return nil }

        let before = pasteboard.changeCount
        keystroke.postCopy(pid: pid)

        // The pasteboard is read *only after observing the change count
        // move*. If nothing is selected, ⌘C copies nothing, the clipboard
        // still holds whatever the user copied ten minutes ago, and reading
        // it here would rewrite that instead — silently, and looking like the
        // model hallucinating rather than like a capture fault.
        guard wait(upTo: copyBudget, until: { pasteboard.changeCount != before }) else {
            return nil
        }

        // An app clears the pasteboard and writes it in two steps, so there
        // is a window where the count has moved and the data has not landed.
        var captured: String?
        _ = wait(upTo: settleBudget) {
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                return false
            }
            captured = text
            return true
        }

        // The writer was the target app, not us, so the transaction has to be
        // told which change count to treat as its own.
        transaction.expect(changeCount: pasteboard.changeCount)
        transaction.restoreIfUnchanged()

        return captured
    }

    private func wait(upTo budget: Duration, until condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + budget
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: pollInterval.timeInterval)
        }
    }
}

/// Posts ⌘C and ⌘V. Lives here because synthesising ⌘C *is* the clipboard
/// capture path; `ReplacementService` reaches across for the ⌘V. If you went
/// looking for the paste keystroke under a replacement-sounding name and
/// could not find it, that is why.
///
/// **This type is the one piece of TextBridge with no automated test, and
/// that is deliberate.** Posting a real `CGEvent` from a test bundle types
/// into whatever the user happens to have focused, which makes the suite
/// unsafe to run while somebody is working. Everything either side of the
/// keystroke is driven through `KeystrokeCopying` / `KeystrokePosting`. See
/// "What is verified, and how" in `AGENTS.md` for the manual check.
///
/// Empirical: a synthetic ⌘C only reaches an app's `copy:` via a **menu key
/// equivalent**. Real apps have an Edit menu, so this works against them; a
/// purpose-built fixture app needs one installed explicitly or the keystroke
/// lands nowhere and looks like the event failing to post.
public final class SyntheticKeystroke: KeystrokeCopying, KeystrokePosting {
    private static let cKeyCode: CGKeyCode = 8
    private static let vKeyCode: CGKeyCode = 9

    public init() {}

    public func postCopy(pid: pid_t) { post(Self.cKeyCode, to: pid) }
    public func postPaste(pid: pid_t) { post(Self.vKeyCode, to: pid) }

    /// Posted to the target pid rather than the HID tap, so a mistimed event
    /// cannot land in a different app than the one we validated against.
    private func post(_ keyCode: CGKeyCode, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
