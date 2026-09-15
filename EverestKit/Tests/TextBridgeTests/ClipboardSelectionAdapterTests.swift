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

            #expect(adapter(pasteboard, keystroke: keystroke).copySelection(pid: 501) == nil)
            #expect(keystroke.copies == 1)
            #expect(pasteboard.string(forType: .string) == "copied ten minutes ago")
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
