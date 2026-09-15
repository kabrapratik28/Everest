import AppKit
import Testing

@testable import TextBridge

/// The synthetic ⌘C path, with the keystroke injected. Posting a real
/// `CGEvent` from a test bundle would type into whatever the user happens to
/// have focused, so the keystroke itself is the one piece verified by hand;
/// everything either side of it is driven here.
@Suite("Clipboard capture")
struct ClipboardSelectionAdapterTests {

    private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private func adapter(
        _ pasteboard: NSPasteboard, keystroke: FakeCopyKeystroke
    ) -> ClipboardSelectionAdapter {
        ClipboardSelectionAdapter(
            pasteboard: pasteboard,
            keystroke: keystroke,
            copyBudget: .milliseconds(40),
            settleBudget: .milliseconds(20),
            pollInterval: .milliseconds(4)
        )
    }

    /// The second layer against the worst bug in the capture chain. If
    /// nothing is selected, ⌘C copies nothing, the clipboard still holds
    /// whatever the user copied ten minutes ago, and a naive implementation
    /// reads that and rewrites it — a URL, or text from their password
    /// manager. The bug is silent and looks like the model hallucinating
    /// rather than like a capture fault.
    @Test("returns nil rather than the stale clipboard when nothing was copied")
    func returnsNilWhenTheChangeCountNeverMoves() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("copied ten minutes ago", forType: .string)
            let keystroke = FakeCopyKeystroke()  // the target copies nothing
            let before = pasteboard.changeCount

            #expect(adapter(pasteboard, keystroke: keystroke).copySelection(pid: 501) == nil)
            #expect(keystroke.copies == 1)
            #expect(pasteboard.string(forType: .string) == "copied ten minutes ago")
            // Untouched, not restored-to-identical. Writing the same bytes
            // back bumps the change count, and a clipboard manager records
            // that as a fresh copy — a duplicate history entry for every
            // hotkey press in an app that cannot answer.
            #expect(pasteboard.changeCount == before)
        }
    }

    /// The budget bounds how long we *wait*, and an earlier version let it
    /// also bound how long we stay responsible. When the target answered after
    /// the budget expired the copy still landed — on the user's clipboard,
    /// with nobody left watching to put it back. Their clipboard was gone for
    /// good and their selected text sat on the general pasteboard indefinitely
    /// for any clipboard-history app to record.
    ///
    /// Measured against real Chrome, the first synthetic ⌘C after launch took
    /// 262 ms of the 400 ms budget, so "slower than the budget" is an ordinary
    /// cold start on a loaded machine, not a pathological app.
    @Test("a copy that lands after the copy budget is still read and still put back")
    func aLateCopyIsStillRestored() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)
            let before = pasteboard.changeCount

            // The write has to come from another thread to land after the
            // budget at all; `NSPasteboard` is not `Sendable` and this one is
            // private to the test, with the main thread parked in `wait`.
            nonisolated(unsafe) let target = pasteboard
            let keystroke = FakeCopyKeystroke()
            keystroke.onCopy = {
                // The target answers well after the copy budget, the way a
                // cold renderer does.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    target.clearContents()
                    target.setString("the selection", forType: .string)
                }
            }

            let adapter = ClipboardSelectionAdapter(
                pasteboard: pasteboard,
                keystroke: keystroke,
                copyBudget: .milliseconds(30),
                settleBudget: .milliseconds(400),
                pollInterval: .milliseconds(4)
            )
            let captured = adapter.copySelection(pid: 501)

            // Let a late write land even when nothing waited for it, so the
            // assertion below is about the clipboard's final state rather
            // than about a race the old code happened to win.
            let deadline = ContinuousClock.now + .seconds(2)
            while pasteboard.changeCount == before, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }

            #expect(captured == "the selection")
            #expect(pasteboard.string(forType: .string) == "the user's clipboard")
        }
    }

    @Test("returns the selection the target copied and puts the user's clipboard back")
    func returnsTheCopiedSelectionAndRestoresTheClipboard() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let keystroke = FakeCopyKeystroke()
            keystroke.onCopy = {
                pasteboard.clearContents()
                pasteboard.setString("the selection", forType: .string)
            }

            let captured = adapter(pasteboard, keystroke: keystroke).copySelection(pid: 501)

            #expect(captured == "the selection")
            #expect(pasteboard.string(forType: .string) == "the user's clipboard")
        }
    }

    /// `copySelection` returns nil *before* posting ⌘C, because that keystroke
    /// makes the target app overwrite the clipboard and we would be unable to
    /// put it back.
    @Test("declines without posting a keystroke when the clipboard cannot be borrowed")
    func declinesBeforePostingWhenTheClipboardCannotBeBorrowed() throws {
        withPrivatePasteboard { pasteboard in
            let huge = Data(repeating: 0x5A, count: 20 * 1024 * 1024)
            let item = NSPasteboardItem()
            item.setData(huge, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let changeCountBefore = pasteboard.changeCount

            let keystroke = FakeCopyKeystroke()

            #expect(adapter(pasteboard, keystroke: keystroke).copySelection(pid: 501) == nil)
            #expect(keystroke.copies == 0, "no keystroke was posted")
            #expect(pasteboard.changeCount == changeCountBefore)
            #expect(pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge)
        }
    }

    /// An app clears the pasteboard and writes it in two steps, so there is a
    /// window where the count has moved and the data has not landed. The
    /// settle budget exists for that window. When the second step never
    /// arrives, the answer is nil — not an empty string, and never the
    /// content from before.
    @Test("a change count that moves with no text behind it yields nil, not an empty capture")
    func aClearWithNoWriteBehindItYieldsNil() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let keystroke = FakeCopyKeystroke()
            keystroke.onCopy = { pasteboard.clearContents() }  // step one only

            #expect(adapter(pasteboard, keystroke: keystroke).copySelection(pid: 501) == nil)
            #expect(
                pasteboard.string(forType: .string) == "the user's clipboard",
                "and the user's clipboard is put back"
            )
        }
    }
}
