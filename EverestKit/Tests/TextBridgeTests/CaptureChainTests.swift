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

    /// A zero-length range is the app telling us plainly that the caret is
    /// somewhere with nothing selected. Falling through to ⌘C there copies
    /// nothing, leaves whatever the user copied ten minutes ago on the
    /// clipboard, and rewrites *that* — silently, and looking like the model
    /// hallucinated rather than like a capture fault.
    @Test("a zero-length selected range stops the chain instead of falling through to the clipboard")
    func zeroLengthRangeStopsTheChain() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = ""
        ax.range = CFRange(location: 12, length: 0)
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

        #expect(throws: CaptureError.noSelection) {
            _ = try coordinator(ax).capture()
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

        #expect(throws: CaptureError.noSelection) {
            _ = try coordinator(ax, clipboard: clipboard).capture()
        }
        #expect(ax.manualAccessibilityEnables == 1)
        #expect(ax.focusResolutions == 2)
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
