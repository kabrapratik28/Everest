import ApplicationServices
import Testing

@testable import TextBridge

@Suite("Strategy cache")
struct StrategyCacheTests {

    private func coordinator(
        _ ax: FakeAccessibility,
        clipboard: FakeClipboardCapture,
        system: FakeSystem = FakeSystem(
            frontmost: FrontmostApp(pid: 501, bundleID: "com.example.opaque", appVersion: "1.0")
        ),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> SelectionCoordinator {
        SelectionCoordinator(
            system: system,
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: [],
            manualAccessibilitySettle: .zero,
            now: now
        )
    }

    private func opaqueApp() -> (FakeAccessibility, FakeClipboardCapture) {
        let ax = FakeAccessibility()  // answers nothing over accessibility
        let clipboard = FakeClipboardCapture()
        clipboard.result = "opaque view text"
        return (ax, clipboard)
    }

    /// A failed accessibility read is synchronous cross-process IPC and the
    /// chain makes several, so re-proving that an app answers nothing costs
    /// most of a second of frozen main thread on every hotkey press. The cache
    /// exists to skip that work — and this test is what stops the guard test
    /// below from being vacuous.
    @Test("a remembered clipboard app skips the expensive accessibility rungs next time")
    func warmClipboardEntrySkipsTheAccessibilityChain() throws {
        let (ax, clipboard) = opaqueApp()
        let subject = coordinator(ax, clipboard: clipboard)

        _ = try subject.capture()
        #expect(ax.focusResolutions == 2, "cold: resolve, enable manual accessibility, resolve again")
        #expect(ax.manualAccessibilityEnables == 1)

        _ = try subject.capture()

        #expect(ax.manualAccessibilityEnables == 1, "the expensive rung is not repeated")
        #expect(clipboard.attempts == 2)
    }

    /// The correctness boundary. An earlier version read the cache first and
    /// sent a remembered `.clipboard` app straight to the synthetic copy,
    /// which skipped focus resolution and the secure-role refusal and left
    /// nothing but the process-wide flag between Everest and a web password
    /// field — a flag those fields do not set. The cache is allowed to skip
    /// *work*. It is never allowed to skip a *refusal*.
    @Test("a warm clipboard cache entry never lets capture skip the secure check")
    func warmClipboardEntryStillRefusesASecureField() throws {
        let (ax, clipboard) = opaqueApp()
        let subject = coordinator(ax, clipboard: clipboard)

        _ = try subject.capture()
        #expect(clipboard.attempts == 1)
        let focusesAfterLearning = ax.focusResolutions

        // Same app, one keystroke later: focus is now in a web password input.
        // Subrole set, process-wide secure-input flag still false.
        ax.focused = testElement()
        ax.role = "AXTextField"
        ax.subrole = "AXSecureTextField"
        ax.selected = "hunter2"

        #expect(throws: CaptureError.secureField) {
            _ = try subject.capture()
        }
        #expect(
            ax.focusResolutions == focusesAfterLearning + 1,
            "focus is resolved even on the cached path, because rung 4 needs an element"
        )
        #expect(clipboard.attempts == 1, "no keystroke was posted")
        #expect(ax.textReads == 0, "the password was never read")
    }

    /// Without expiry, one bad reading pins an app to the clipboard path
    /// forever. An Electron app answers nothing until *something* enables its
    /// tree, and that something may have quit since.
    @Test("a cache entry expires so a bad reading is not permanent")
    func cacheEntryExpiresAndTheAppIsReprobed() throws {
        let (ax, clipboard) = opaqueApp()
        var instant = ContinuousClock.now
        let subject = coordinator(ax, clipboard: clipboard, now: { instant })

        _ = try subject.capture()
        #expect(ax.manualAccessibilityEnables == 1)

        instant = instant.advanced(by: StrategyCache.reprobeInterval + .seconds(1))
        _ = try subject.capture()

        #expect(ax.manualAccessibilityEnables == 2, "the route is re-probed, not pinned")
    }

    /// What we learned was learned about a different binary, so an upgrade
    /// invalidates naturally. The version lives in the value rather than the
    /// key so the mismatch *replaces* the entry instead of adding a second
    /// one, which is what keeps the cache from growing without bound.
    @Test("an app version change invalidates the entry instead of adding a second one")
    func appVersionChangeInvalidatesTheEntry() throws {
        let (ax, clipboard) = opaqueApp()
        let system = FakeSystem(
            frontmost: FrontmostApp(pid: 501, bundleID: "com.example.opaque", appVersion: "1.0")
        )
        let subject = coordinator(ax, clipboard: clipboard, system: system)

        _ = try subject.capture()
        #expect(ax.manualAccessibilityEnables == 1)

        system.frontmost = FrontmostApp(
            pid: 501, bundleID: "com.example.opaque", appVersion: "2.0"
        )
        _ = try subject.capture()

        #expect(ax.manualAccessibilityEnables == 2, "the upgraded binary is probed afresh")
    }

    /// A cached answer is a hint, never a gate. A stale entry costs one wasted
    /// copy, never a permanent downgrade to a path that cannot be written back.
    @Test("a warm clipboard entry that comes up empty falls through to a proper probe")
    func staleClipboardEntryFallsThroughRatherThanFailing() throws {
        let (ax, clipboard) = opaqueApp()
        let subject = coordinator(ax, clipboard: clipboard)

        _ = try subject.capture()

        // The app's accessibility tree has come up since — a screen reader, or
        // a relaunch — and the clipboard route now yields nothing.
        clipboard.result = nil
        ax.focused = testElement()
        ax.selected = "now readable"
        ax.range = CFRange(location: 0, length: 12)

        let snapshot = try subject.capture()

        #expect(snapshot.text == "now readable")
        #expect(snapshot.isRangeDerived == false)
    }

    /// The cache is keyed by app, and an app is not one text engine. Chrome is
    /// one bundle identifier for both Google Docs, which paints its document
    /// into a canvas and can only be read through ⌘C, and Gmail, which is
    /// ordinary DOM and can be read *and written back* in place. Recording the
    /// Docs reading against the whole app costs Gmail its in-place rewrite for
    /// the next ten minutes, and a copy-only result where a replacement was
    /// possible is a downgrade the user can neither see nor undo.
    ///
    /// So what is remembered is the app being dark, not the route being
    /// convenient. The cache exists to skip re-proving that an app answers
    /// nothing, which costs a `AXManualAccessibility` write and a settle on
    /// every press; an app that handed over a focused element on the first ask
    /// has already proved it is not that app, and probing it again is cheap.
    @Test("a clipboard capture in an app whose tree answers does not pin the app to ⌘C")
    func clipboardCaptureDoesNotPinAnAppWhoseTreeAnswers() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()  // the tree is alive and answers at once
        ax.range = CFRange(location: 0, length: 0)  // ... but focus is in the canvas editor's
        ax.characters = 0  // ... empty offscreen input
        let clipboard = FakeClipboardCapture()
        clipboard.result = "the sentence painted on the canvas"
        let subject = coordinator(ax, clipboard: clipboard)

        _ = try subject.capture()
        #expect(clipboard.attempts == 1)

        // The next press lands in an ordinary DOM view of the same app.
        ax.range = CFRange(location: 4, length: 15)
        ax.selected = "quick brown fox"

        let snapshot = try subject.capture()

        #expect(snapshot.text == "quick brown fox")
        #expect(clipboard.attempts == 1, "the remembered route did not pre-empt the real one")
    }

    /// Every clipboard borrow exposes the selection to any clipboard history
    /// app, so a stale entry must cost *one* wasted copy, not one per hotkey
    /// press forever. Falling through has to replace what we learned.
    @Test("once an app starts answering, the remembered clipboard route is replaced")
    func recoveredAppStopsBorrowingTheClipboard() throws {
        let (ax, clipboard) = opaqueApp()
        let subject = coordinator(ax, clipboard: clipboard)

        _ = try subject.capture()
        #expect(clipboard.attempts == 1)

        ax.focused = testElement()
        ax.selected = "now readable"
        ax.range = CFRange(location: 0, length: 12)
        clipboard.result = nil

        _ = try subject.capture()
        #expect(clipboard.attempts == 2, "one wasted copy proving the stale entry is stale")

        _ = try subject.capture()
        #expect(clipboard.attempts == 2, "and never again")
    }
}
