import ApplicationServices
import Testing

@testable import TextBridge

@Suite("Capture chain")
struct CaptureChainTests {

    private func coordinator(
        _ ax: FakeAccessibility,
        clipboard: FakeClipboardCapture = FakeClipboardCapture(),
        bundleID: String = "com.example.editor"
    ) -> SelectionCoordinator {
        SelectionCoordinator(
            system: FakeSystem(
                frontmost: FrontmostApp(pid: 501, bundleID: bundleID, appVersion: "1.0")
            ),
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: [],
            // Zero, so the suite never sleeps. The production default is a real
            // wait; what is under test is that the retry happens exactly once.
            manualAccessibilitySettle: .zero
        )
    }

    /// A zero-length range in an element that holds text is the app telling us
    /// plainly that the caret is somewhere with nothing selected. Falling
    /// through to ⌘C there copies nothing, leaves whatever the user copied ten
    /// minutes ago on the clipboard, and rewrites *that* — silently, and
    /// looking like the model hallucinated rather than like a capture fault.
    ///
    /// The character count is part of the fixture rather than decoration: a
    /// caret at offset 12 is only coherent in an element with at least twelve
    /// characters in it, and it is having them that makes the app's answer
    /// about the user's selection rather than about an empty box.
    @Test("a zero-length selected range stops the chain instead of falling through to the clipboard")
    func zeroLengthRangeStopsTheChain() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = ""
        ax.range = CFRange(location: 12, length: 0)
        ax.characters = 40
        let clipboard = FakeClipboardCapture()
        clipboard.result = "something the user copied ten minutes ago"

        #expect(throws: CaptureError.noSelection) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
        #expect(clipboard.attempts == 0, "⌘C must not be posted with nothing selected")
    }

    /// A zero-length range together with non-empty selected text is a
    /// contradiction. Trusting the text would mean writing the rewrite back
    /// through a zero-length range later, which inserts a second copy rather
    /// than replacing anything.
    @Test("a zero-length range contradicting non-empty selected text is refused")
    func zeroLengthRangeBeatsNonEmptySelectedText() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = "contradiction"
        ax.range = CFRange(location: 12, length: 0)
        ax.characters = 40
        let clipboard = FakeClipboardCapture()
        clipboard.result = "and the clipboard is not consulted either"

        #expect(throws: CaptureError.noSelection) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
    }

    /// The same zero-length range, read off an element that holds no
    /// characters at all, means the opposite thing. Measured against Chrome
    /// 153 on a page built the way Google Docs is built — prose painted into a
    /// `<canvas>`, keyboard focus parked in an empty `contenteditable` in an
    /// offscreen iframe — Chrome answers `AXSelectedTextRange {0, 0}`,
    /// `AXSelectedText ""` and `AXNumberOfCharacters 0`. All three are true
    /// about that element and none of them is about the sentence the user can
    /// see highlighted, so stopping here is stopping on an answer to a
    /// question nobody asked. ⌘C, which Docs handles normally, is the rung
    /// that can still read it.
    ///
    /// The range is still authoritative over anything read *beside* it: a
    /// non-empty `AXSelectedText` next to a zero-length range is a
    /// contradiction whichever branch we are on, and text reconstructed
    /// through a zero-length range is not the user's selection either.
    @Test("a zero-length range in an element holding no text hands off instead of stopping")
    func zeroLengthRangeInATextlessElementHandsOff() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.range = CFRange(location: 0, length: 0)
        ax.characters = 0
        ax.selected = "contradiction"
        ax.stringForRange = "the whole document"
        let clipboard = FakeClipboardCapture()
        clipboard.result = "the sentence painted on the canvas"

        let snapshot = try coordinator(ax, clipboard: clipboard).capture()

        #expect(snapshot.text == "the sentence painted on the canvas")
        #expect(ax.textReads == 0, "the range settles this element before any text is read")
    }

    /// Handing off needs positive evidence that the element is empty, not the
    /// absence of evidence that it is not. An element that reports a
    /// zero-length range and does not implement `AXNumberOfCharacters` has
    /// still said the one thing it said plainly, and treating silence as
    /// "empty" would buy a clipboard borrow — and the selection leak to every
    /// clipboard-history app that comes with it — for every app that simply
    /// does not answer that question.
    @Test("an element that does not report a character count keeps the plain refusal")
    func unknownCharacterCountStillStopsTheChain() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = ""
        ax.range = CFRange(location: 12, length: 0)
        ax.characters = nil  // the attribute is not implemented at all
        let clipboard = FakeClipboardCapture()
        clipboard.result = "something the user copied ten minutes ago"

        #expect(throws: CaptureError.noSelection) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
    }

    /// Rung 7. `AXStringForRange` reconstructs the text *from the range*, and
    /// Chromium and Electron have a long-standing off-by-one in
    /// `AXSelectedTextRange`. The shifted result is still well-formed prose, so
    /// nothing downstream can detect it and revalidation would re-read through
    /// the same shifted range and agree with itself. The snapshot therefore
    /// has to carry the fact, so `ReplacementService` can refuse to write it.
    @Test("text reconstructed from a range is marked range-derived")
    func rangeReadMarksSnapshotRangeDerived() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = ""  // the app implements the attribute and answers nothing
        ax.range = CFRange(location: 4, length: 7)
        ax.stringForRange = "content"

        let snapshot = try coordinator(ax).capture()

        #expect(snapshot.text == "content")
        #expect(snapshot.isRangeDerived)
    }

    @Test("text the app handed over directly is not marked range-derived")
    func directReadIsNotRangeDerived() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = "content"
        ax.range = CFRange(location: 4, length: 7)
        ax.stringForRange = "ontent "  // the shifted reading we must not prefer

        let snapshot = try coordinator(ax).capture()

        #expect(snapshot.text == "content")
        #expect(snapshot.isRangeDerived == false)
        #expect(ax.rangeStringReads == 0, "the range read is not even attempted")
    }

    /// Rung 8. Chromium keeps its accessibility tree switched off until
    /// something asks, and until then the whole subtree is invisible: no
    /// focused element, no selected text, no range. That is indistinguishable
    /// from "nothing is selected", which is why the chain asks rather than
    /// giving up. The tree is not ready when the attribute write returns, so
    /// focus is re-resolved from scratch afterwards.
    @Test("an app with its accessibility tree off is retried once after AXManualAccessibility")
    func manualAccessibilityEnablesTheTreeAndRetriesOnce() throws {
        let ax = FakeAccessibility()
        ax.focused = nil
        ax.onEnableManualAccessibility = { [weak ax] in
            ax?.focused = testElement()
            ax?.selected = "electron text"
            ax?.range = CFRange(location: 0, length: 13)
        }

        let snapshot = try coordinator(ax).capture()

        #expect(snapshot.text == "electron text")
        #expect(ax.manualAccessibilityEnables == 1)
        #expect(ax.focusResolutions == 2, "resolved once, then once more after the settle")
    }

    /// Retry once, never in a loop. If the tree did not appear after the
    /// settle it is not going to, and a retry loop turns a failed capture into
    /// a visible freeze on the main thread.
    @Test("the manual-accessibility retry happens exactly once, never in a loop")
    func manualAccessibilityDoesNotLoop() throws {
        let ax = FakeAccessibility()  // answers nothing, ever
        let clipboard = FakeClipboardCapture()
        clipboard.result = nil

        // Which error this is belongs to the test below, not here: two tests
        // failing for one root cause make one regression look like two.
        #expect(throws: (any Error).self) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
        #expect(ax.manualAccessibilityEnables == 1)
        #expect(ax.focusResolutions == 2)
    }

    /// Running out of rungs is not the same finding as the app saying nothing
    /// is selected, and collapsing them into one error makes the app tell a
    /// user who *has* selected text to go and select some text. They do, it
    /// fails the same way, and the only thing they learn is that Everest is
    /// broken.
    ///
    /// Only one of the two is a claim about the user. `.noSelection` is the
    /// app's own answer, read off an element that holds text and reports none
    /// of it selected. This is a statement about us: every route we have came
    /// back empty, and which of the two possible reasons it was — nothing
    /// selected, or text we cannot reach — is precisely what we could not
    /// determine. The sentence has to own that, so the error has to carry it.
    @Test("an app that answers nothing anywhere is not reported as an empty selection")
    func exhaustedChainIsNotReportedAsAnEmptySelection() throws {
        let ax = FakeAccessibility()  // answers nothing, ever
        let clipboard = FakeClipboardCapture()  // and ⌘C comes back with nothing

        #expect(throws: CaptureError.nothingCaptured) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
    }

    /// Rung 9, last for three reasons: it is the only path that disturbs the
    /// user's clipboard, the only one that depends on the target having a
    /// working Edit menu Copy, and it leaks the selection to any clipboard
    /// history app for as long as the borrow lasts.
    @Test("an app that answers no accessibility at all falls through to the clipboard")
    func clipboardFallbackCapturesWhenAccessibilityAnswersNothing() throws {
        let ax = FakeAccessibility()  // an accessibility-opaque view
        let clipboard = FakeClipboardCapture()
        clipboard.result = "opaque view text"

        let snapshot = try coordinator(ax, clipboard: clipboard).capture()

        #expect(snapshot.text == "opaque view text")
        #expect(snapshot.range == nil, "there is no range to prove anything with")
        #expect(snapshot.isRangeDerived == false)
        #expect(clipboard.attempts == 1)
    }
}
