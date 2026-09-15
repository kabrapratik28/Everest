import AppKit
import ApplicationServices
import Testing

@testable import TextBridge

@Suite("Replacement")
struct ReplacementTests {

    private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private let liveRange = CFRange(location: 3, length: 12)

    /// Deliberately a *different* `AXUIElement` reference for the same
    /// interface object than the one the fake hands back. Two references
    /// obtained at different moments are equal but not identical, so pointer
    /// comparison would report a mismatch every single time and no rewrite
    /// would ever be written back. `CFEqual` is what compares identity.
    private func snapshot(
        text: String = "the original",
        pid: pid_t = 501,
        range: CFRange? = CFRange(location: 3, length: 12),
        isRangeDerived: Bool = false,
        bundleID: String = "com.example.editor"
    ) -> TargetSnapshot {
        TargetSnapshot(
            pid: pid,
            bundleID: bundleID,
            appVersion: "1.0",
            element: AXUIElementCreateApplication(501),
            text: text,
            range: range,
            role: "AXTextArea",
            isEditable: true,
            isRangeDerived: isRangeDerived,
            viaClipboard: false
        )
    }

    /// Exactly what `SelectionCoordinator.readViaClipboard` builds: the
    /// application element standing in for a field, no range, no role.
    private func viaClipboardSnapshot(
        bundleID: String = "com.sublimetext.4", text: String = "the original"
    ) -> TargetSnapshot {
        TargetSnapshot(
            pid: 501,
            bundleID: bundleID,
            appVersion: "1.0",
            element: AXUIElementCreateApplication(501),
            text: text,
            range: nil,
            role: nil,
            isEditable: false,
            isRangeDerived: false,
            viaClipboard: true
        )
    }

    private func liveTarget() -> FakeAccessibility {
        let ax = FakeAccessibility()
        ax.focused = AXUIElementCreateApplication(501)
        ax.selected = "the original"
        ax.range = liveRange
        ax.settable = true
        return ax
    }

    /// What the target app read off the pasteboard when its ⌘V finally
    /// arrived. Written from a background thread while the main thread is
    /// parked inside `apply`, so the access is genuinely cross-thread.
    private final class LateReader: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: String?
        private var done = false

        func record(_ text: String?) {
            lock.lock()
            defer { lock.unlock() }
            recorded = text
            done = true
        }

        var hasRead: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        var text: String? {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private func service(
        _ ax: FakeAccessibility,
        keystroke: FakeKeystroke,
        pasteboard: NSPasteboard,
        clipboard: FakeClipboardCapture = FakeClipboardCapture(),
        consumptionBudget: Duration = .milliseconds(40),
        system: FakeSystem = FakeSystem(
            frontmost: FrontmostApp(pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
        )
    ) -> ReplacementService {
        ReplacementService(
            system: system,
            accessibility: ax,
            keystroke: keystroke,
            clipboard: clipboard,
            pasteboard: pasteboard,
            // Small but real, and now the floor on how long `apply` takes on
            // route two rather than a ceiling: the rewrite has to outlive an
            // early consumption reading.
            consumptionBudget: consumptionBudget,
            consumptionPollInterval: .milliseconds(4)
        )
    }

    /// `observeConsumption` takes **any** selection change as proof of paste,
    /// so it can confirm a paste that has not happened — a reflow, a scroll,
    /// an async relayout. That much is a known and accepted trade, because
    /// the alternative false negative pastes the rewrite *and* copies it and
    /// the user duplicates a paragraph.
    ///
    /// What is not acceptable is what used to follow. A false positive
    /// restored the user's clipboard immediately, and the real ⌘V — still in
    /// flight — then pasted *their old clipboard* into their document, while
    /// Everest reported `.replaced`. A silent wrong write to a document,
    /// which they may never notice and cannot undo from here.
    ///
    /// So the rewrite stays on the pasteboard for the whole budget however
    /// early consumption is read. The residual cost is that for that window
    /// the pasteboard holds our rewrite, so a user pressing ⌘V themselves
    /// inside it gets the rewrite instead of what they copied — visible at
    /// once, and fixed by copying again. This test is about the content a
    /// late paste sees, not about the false positive, which stands.
    @Test("a late paste reads the rewrite, never the clipboard we were about to restore")
    func theRewriteOutlivesAnEarlyConsumptionReading() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = false  // route one declines, so route two runs
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let reader = LateReader()
            nonisolated(unsafe) let board = pasteboard
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                // Not our paste: the selection moved but still holds the
                // user's original text. Consumption is read on the first poll
                // while the ⌘V is still in flight.
                ax.range = CFRange(location: 9, length: 12)
                ax.selected = "the original"

                // The ⌘V lands later and reads whatever is on the pasteboard
                // at that moment. That is the byte sequence which ends up in
                // the user's document.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
                    reader.record(board.string(forType: .string))
                }
            }

            _ = service(
                ax, keystroke: keystroke, pasteboard: pasteboard,
                consumptionBudget: .milliseconds(300)
            ).apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            let deadline = ContinuousClock.now + .seconds(2)
            while !reader.hasRead, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }

            #expect(reader.text == "the rewrite")
            #expect(
                pasteboard.string(forType: .string) == "the user's clipboard",
                "and the clipboard is still given back afterwards"
            )
        }
    }

    /// Auto-replace, and what it actually changes: `isEditable` stops being a
    /// veto on route two.
    ///
    /// It was always the weakest signal in `apply`. By the time control
    /// reaches it the validator has proved the focused element reports our
    /// exact text *at our exact range*, which is a stronger statement about
    /// the target than any role or settability flag — `AXSelectionAdapter`
    /// already says so in its own comment. Real editors, WebKit
    /// `contenteditable` among them, accept typing while reporting neither
    /// attribute settable, and those are the targets that were returning
    /// copy-only and asking the user to paste by hand.
    ///
    /// The downside is bounded and already built: if the target really is
    /// read-only the paste is ignored, `observeConsumption` sees the
    /// selection unchanged, and the outcome is the same copy-only the user
    /// got before, one budget later.
    @Test("auto-replace offers the paste even when accessibility calls the target read-only")
    func autoReplacePastesIntoATargetReportedNotEditable() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = false  // route one declines
            ax.editable = false  // and accessibility calls the target read-only
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                // The target takes it: the selection collapses to a caret.
                ax.selected = ""
                ax.range = CFRange(location: 15, length: 0)
            }

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: true, keepOutOfHistory: false)

            #expect(outcome == .replaced)
            #expect(keystroke.pastes == 1)
        }
    }

    /// **A write that reports success and changes nothing.**
    ///
    /// Measured in Chrome 153 against Linear, 2026-09-15:
    /// `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` returns
    /// `.success` on a field that reports `settable`, and the value is
    /// unchanged at +120 ms and at +1 s. The same is reported for
    /// chatgpt.com and chat.google.com. React owns the input and never sees
    /// the AX write, so nothing lands. A plain `contenteditable` in the same
    /// Chrome replaces correctly, which is why this looked browser-shaped
    /// and is not.
    ///
    /// Everest believed the return value: the live trace from a real
    /// reproduction reads `captured(rung: selectedText, length: 23,
    /// isEditable: true, role: AXTextArea)` then `outcome(replaced)`, four
    /// presses in a row, with nothing written and a green tick each time.
    ///
    /// The confirm is deliberately **positive proof of failure**, never
    /// absence of proof of success — the same shape as the rung-9 confirm,
    /// and for the same reason. Chaining into route two on a false negative
    /// pastes the rewrite twice, and a duplicated paragraph is worse than a
    /// rewrite that did not land. So both signals must say nothing moved:
    /// the selection still reports our exact captured text *and* the
    /// element holds the same number of characters.
    @Test("a route-one write that reports success but changes nothing falls through to the paste")
    func routeOneThatReportsSuccessWithoutWritingFallsThrough() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = true
            ax.characters = 12
            ax.writeLands = false  // Chromium: success, and nothing moves
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                ax.selected = ""
                ax.range = CFRange(location: 15, length: 0)
            }

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: true, keepOutOfHistory: false)

            #expect(ax.writes == ["the rewrite"], "route one is still tried first")
            #expect(keystroke.pastes == 1, "and the paste is what actually lands")
            #expect(outcome == .replaced)
        }
    }

    /// The other half, and the one that keeps the old guard honest: a write
    /// that *did* land must not be pasted on top of. Without this the fix
    /// above would be free to confirm sloppily and duplicate a paragraph in
    /// every app where route one works.
    @Test("a route-one write that lands is never pasted a second time")
    func routeOneThatLandsIsNotPastedAgain() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = true
            ax.characters = 12
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: true, keepOutOfHistory: false)

            #expect(outcome == .replaced)
            #expect(ax.writes == ["the rewrite"])
            #expect(keystroke.pastes == 0, "route one landed, so nothing may be pasted over it")
        }
    }

    /// The setting has to reach the write, not merely exist. `handOff` is the
    /// single funnel every copy-only outcome goes through, so a flag that
    /// stops short of it is a preference the user can toggle with no effect —
    /// and `PasteboardTransaction`'s own test would still pass, because it
    /// calls `writeDurable` directly.
    @Test("keeping rewrites out of history reaches the copy-only write")
    func historySettingReachesTheDurableWrite() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            // Range-derived, so this refuses early and lands in `handOff`
            // without any of route one or two running.
            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply(
                    "the rewrite", to: snapshot(isRangeDerived: true),
                    autoReplace: true, keepOutOfHistory: true)

            #expect(outcome == .copiedOnly(
                cause: .rangeDerived,
                reason: "the selection was reconstructed from a range and cannot be verified"))
            #expect(pasteboard.string(forType: .string) == "the rewrite", "still pasteable")
            #expect(
                pasteboard.types?.contains(.init("org.nspasteboard.TransientType")) == true,
                "and marked so a clipboard manager skips it")
        }
    }

    /// The fallback must not destroy what the restore just refused to touch.
    ///
    /// `restoreIfUnchanged` declining means one thing: the clipboard holds
    /// something newer than ours, because the user copied while the rewrite
    /// ran. Handing off then writes the rewrite straight over it — their
    /// fresh copy gone, and gone to the very mechanism that exists to protect
    /// it.
    ///
    /// **This path was opened by the fix for the leaked borrow.** Before it,
    /// the declined restore left the borrow held, `handOff` could not acquire,
    /// and the user's copy survived behind a false "another rewrite is using
    /// the clipboard". That fix was right — a false error is not a reason to
    /// keep a leak — but it converted a wrong message into data loss, and
    /// this is the half that was missing.
    @Test("a clipboard the user changed mid-rewrite is not overwritten by the fallback")
    func aClipboardChangedMidRewriteIsNotOverwritten() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = false  // route one declines, so route two runs
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                // The user presses ⌘C in another window while the rewrite is
                // in flight. The selection is untouched, so the paste is
                // never observed as consumed.
                pasteboard.clearContents()
                pasteboard.setString("what the user just copied", forType: .string)
            }

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply(
                    "the rewrite", to: snapshot(),
                    autoReplace: false, keepOutOfHistory: false)

            #expect(
                pasteboard.string(forType: .string) == "what the user just copied",
                "their copy is newer than ours and survives")
            #expect(
                outcome
                    == .heldForManualCopy(
                        cause: .clipboardChanged,
                        reason:
                            "the target did not accept the paste, and something else was copied while it ran, so the rewrite is only in this panel"
                    ))
        }
    }

    /// The two settings must compose: with both on — the shipped defaults —
    /// a rewrite that lands in the document leaves the clipboard as the user
    /// left it.
    ///
    /// Parameterised on the history setting because that is the composition
    /// claim itself: a successful auto-replace never reaches `writeDurable`,
    /// so `keepOutOfHistory` has no bearing on this path and the test says so
    /// rather than leaving it to be assumed. The other two combinations
    /// collapse into the same root cause — `autoReplace` only decides whether
    /// route two is *attempted*, and once it runs it restores identically.
    ///
    /// Asserting the exact original rather than the absence of the rewrite:
    /// restoring the *wrong* thing also satisfies "the rewrite is not there",
    /// and the fallback overwriting a newer clipboard is a failure this
    /// module has already produced once.
    @Test(
        "a successful auto-replace leaves the clipboard as it was, either history setting",
        arguments: [true, false])
    func autoReplaceLeavesTheClipboardUntouched(keepOutOfHistory: Bool) throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)
            let before = pasteboard.changeCount

            let ax = liveTarget()
            ax.settable = false  // route one declines
            ax.editable = false  // and accessibility calls it read-only, so auto-replace runs it
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                ax.selected = ""
                ax.range = CFRange(location: 15, length: 0)
            }

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply(
                    "the rewrite", to: snapshot(),
                    autoReplace: true, keepOutOfHistory: keepOutOfHistory)

            #expect(outcome == .replaced)
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")

            // The *contents* come back; the change count deliberately does
            // not, and asserting it would pin a promise the design cannot
            // keep. `writeTransient` moves it and the restore moves it again,
            // so a clipboard manager sees a write either way — what it does
            // with a write identical to the entry it already holds is its
            // own business, and the same third-party unknown as the markers.
            #expect(pasteboard.changeCount > before, "and the restore is a write, not a rollback")
        }
    }

    /// A rung-9 target has no element and no range, so the validator can
    /// never confirm it — but the mechanism that *captured* the text still
    /// works, and asking it again is evidence the validator does not have.
    /// Same text back ⇒ the selection has not moved ⇒ paste.
    ///
    /// Sublime Text is the case: measured, it exposes no editable element at
    /// all, so every rewrite there was `.copiedOnly`, and `copiedOnly` means
    /// a durable write — the "safe" fallback destroying the clipboard on
    /// every single use.
    ///
    /// Confirmed the same way, because `observeConsumption` cannot work here
    /// either: a landed paste replaces the selection, so a third ⌘C copies
    /// nothing at all. That is the signal, and it is why success is
    /// reportable rather than every rewrite ending in a panel.
    @Test("a clipboard-captured target is pasted into when the re-read still matches")
    func clipboardCaptureIsPastedWhenTheReReadMatches() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let ax = FakeAccessibility()  // Sublime: nothing at all
            let keystroke = FakeKeystroke()
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"  // the re-read agrees

            keystroke.onPaste = {
                // The paste lands, so the selection is gone and the
                // confirming ⌘C will copy nothing.
                clipboard.result = nil
            }

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(outcome == .replaced)
            #expect(keystroke.pastes == 1)
            #expect(
                pasteboard.string(forType: .string) == "the user's own clipboard",
                "and his clipboard ends exactly as it started")
        }
    }

    /// **An absence is weak evidence.** The confirm used to accept only
    /// "nothing came back" as proof of a landed paste, and nothing coming
    /// back has more than one cause: Sublime's `copy_with_empty_selection`
    /// defaults on, so ⌘C at a collapsed caret hands over the whole current
    /// line, and a successful paste then looked like a failed one.
    ///
    /// Containment cannot fix it in either direction — a single-line paste
    /// makes the copied line wider than the rewrite, a multi-line paste makes
    /// it narrower — so the reliable signal is the *failure* one: a paste
    /// that was ignored leaves the selection untouched, and ⌘C then returns
    /// exactly what was captured.
    @Test("a confirm that copies something other than the original is a landed paste")
    func aConfirmReturningSomethingElseIsSuccess() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"  // the re-read agrees
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                // Sublime, caret collapsed after the paste: ⌘C gives the
                // whole line, which is neither empty nor the original.
                clipboard.result = "    the rewrite, indented as the line holds it"
            }

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(outcome == .replaced)
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
        }
    }

    /// The other side, and the positive evidence the rule turns on: the
    /// original coming back means the selection was never touched.
    @Test("a confirm that returns exactly the original proves the paste was ignored")
    func aConfirmReturningTheOriginalIsFailure() throws {
        withPrivatePasteboard { pasteboard in
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"  // unchanged by the paste
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            if case .heldForManualCopy(cause: .notPasted, _) = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// Unknown is not success. A confirm that cannot borrow proves nothing,
    /// and the costs are asymmetric: holding shows a panel and keeps the
    /// rewrite, while a wrong `.replaced` dismisses with a tick and the
    /// rewrite is gone from the panel *and* the clipboard.
    @Test("a confirm that cannot borrow holds rather than claiming success")
    func aConfirmThatCannotBorrowHolds() throws {
        withPrivatePasteboard { pasteboard in
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()
            keystroke.onPaste = { clipboard.borrowRefused = true }

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            if case .heldForManualCopy = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// Resolves its promise and lets something else write first, so the
    /// snapshot's change count moves mid-read.
    private final class RacingProvider: NSObject, NSPasteboardItemDataProvider,
        @unchecked Sendable
    {
        let onResolve: @Sendable () -> Void
        init(onResolve: @escaping @Sendable () -> Void) { self.onResolve = onResolve }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            onResolve()
            item.setData(Data("resolved".utf8), forType: type)
        }
    }

    /// Third wrong-cause message on this path today, and the same sentence
    /// each time: "another rewrite is using the clipboard" when nothing is.
    /// It names a cause the user can do nothing about — they did not start a
    /// second rewrite, they copied something.
    ///
    /// The refusal now carries its own reason rather than being inferred from
    /// `Fidelity`, which answers *how complete our copy is* — a different
    /// question, and one enum answering both is how the next reader switches
    /// on the wrong one.
    @Test("a clipboard that moved under the snapshot is reported as changed, not as busy")
    func aClipboardThatMovedUnderTheSnapshotIsNotReportedAsBusy() throws {
        withPrivatePasteboard { pasteboard in
            nonisolated(unsafe) let board = pasteboard
            let provider = RacingProvider {
                board.clearContents()
                board.setString("what the user just copied", forType: .string)
            }
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.tiff])
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

            let ax = liveTarget()
            ax.settable = false  // route one declines, so route two snapshots

            let outcome = service(ax, keystroke: FakeKeystroke(), pasteboard: pasteboard)
                .apply(
                    "the rewrite", to: snapshot(),
                    autoReplace: false, keepOutOfHistory: false)

            if case .heldForManualCopy(cause: .clipboardChanged, _) = outcome {} else {
                Issue.record("expected a changed-clipboard hold, got \(outcome)")
            }
        }
    }

    /// The Sublime shape, which every other clipboard fixture here missed.
    ///
    /// Rung 9 is reached two different ways and they look nothing alike to
    /// the validator. A terminal resolves **no** focused element, so
    /// `validate` stops at `.unverifiable`. Sublime resolves one — measured,
    /// an `AXWindow` — and `CFEqual` against `readViaClipboard`'s application
    /// element is then false, so `validate` stops one line *earlier* at
    /// `.focusMoved`.
    ///
    /// Both are the same fact — a rung-9 snapshot has no element to compare —
    /// arriving by whichever route the app happens to allow. Neither says
    /// anything moved. Every fixture in this file modelled the first shape,
    /// so the paste override looked right and never fired for the app it was
    /// built for.
    @Test("a clipboard target whose focus resolves to a different element is still pasted into")
    func clipboardCaptureWithResolvedFocusIsStillPasted() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let ax = FakeAccessibility()
            ax.focused = testElement(pid: 777)  // a window, not the app element
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()
            keystroke.onPaste = { clipboard.result = nil }

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(outcome == .replaced)
            #expect(keystroke.pastes == 1)
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
        }
    }

    /// And the reason to fix this in the validator rather than by widening
    /// the override's condition: `CFEqual` is checked *before* `isSecure`, so
    /// a rung-9 snapshot whose focus resolves returns `.focusMoved` and the
    /// secure check never runs. Accepting `.focusMoved` as a paste signal
    /// would have pasted into a password field that nothing had looked at.
    @Test("a clipboard target whose resolved focus is secure is refused as secure")
    func clipboardCaptureWithSecureFocusIsRefusedAsSecure() throws {
        withPrivatePasteboard { pasteboard in
            let ax = FakeAccessibility()
            ax.focused = testElement(pid: 777)
            ax.subrole = "AXSecureTextField"
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0)
            #expect(clipboard.attempts == 0, "refused before the re-read")
            if case .copiedOnly(cause: .secureField, _) = outcome {} else {
                Issue.record("expected a secure refusal, got \(outcome)")
            }
        }
    }

    /// The re-read is the whole safety argument, so it has to be able to say
    /// no. A selection that moved while the model was working means the text
    /// we hold is not what is selected now, and pasting would replace the
    /// wrong thing — the unrecoverable case root §6 exists for.
    @Test("a re-read that disagrees refuses the paste and leaves the clipboard alone")
    func aMovedSelectionRefusesThePaste() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let clipboard = FakeClipboardCapture()
            clipboard.result = "something else entirely"  // they selected elsewhere
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0, "nothing was pasted over the wrong text")
            #expect(
                pasteboard.string(forType: .string) == "the user's own clipboard",
                "and the rewrite was not written over their clipboard either")
            if case .heldForManualCopy(cause: .notPasted, _) = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// Validation ran, then up to 520 ms of blocking copy, then ⌘V, then a
    /// 450 ms hold, then a third copy — and nothing re-asked whether the
    /// world still looked the way the validator found it. The secure-input
    /// window we closed at rung 9 an hour ago was still open twice over,
    /// downstream of it.
    ///
    /// `observeConsumption` already re-checks frontmost every 8 ms on the
    /// grounds that "still frontmost" is a live condition. This path took the
    /// opposite view across more than a second of blocking work.
    @Test("a password field taking focus during the re-read stops the paste")
    func secureInputDuringTheReReadStopsThePaste() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let system = FakeSystem(
                frontmost: FrontmostApp(pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0"))
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            // The copy blocks; the user clicks into a password field while it does.
            clipboard.onCopy = { system.secureInputEnabled = true }
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard, system: system
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0, "no ⌘V into a password field")
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
            if case .heldForManualCopy = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// Same window, the other condition. Separable from the test above:
    /// removing only the secure-input half leaves this one passing.
    @Test("an app that stops being frontmost during the re-read is not pasted into")
    func losingFrontmostDuringTheReReadStopsThePaste() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let system = FakeSystem(
                frontmost: FrontmostApp(pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0"))
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            // They ⌘-Tab away while the copy blocks.
            clipboard.onCopy = {
                system.frontmost = FrontmostApp(
                    pid: 999, bundleID: "com.other.app", appVersion: "1.0")
            }
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard, system: system
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0, "no ⌘V into a document they have left")
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
            if case .heldForManualCopy = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// The confirm is a third synthetic ⌘C and it comes after a 450 ms hold,
    /// so it has a window of its own. Posting it at an app the user has left
    /// reads a selection out of a background document and disturbs the
    /// clipboard to do it.
    @Test("the confirming copy is not posted at an app the user has left")
    func theConfirmIsNotPostedAtABackgroundedApp() throws {
        withPrivatePasteboard { pasteboard in
            let system = FakeSystem(
                frontmost: FrontmostApp(pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0"))
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()
            keystroke.onPaste = {
                system.frontmost = FrontmostApp(
                    pid: 999, bundleID: "com.other.app", appVersion: "1.0")
            }

            _ = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard, system: system
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 1, "the paste itself was legitimate")
            #expect(clipboard.attempts == 1, "but the confirming ⌘C was not posted")
        }
    }

    /// Terminal.app is captured at **rung 5**, not rung 9 — measured, it
    /// supports `AXSelectedText` — so its snapshot is not `viaClipboard` and
    /// never reaches `pasteUnverifiable`, where the terminal list used to
    /// live. Meanwhile `kAXTextAreaRole` is in `editableRoles`, so
    /// `isEditable` is true by role even though `AXValue` is not settable,
    /// and route two posted ⌘V straight at the shell prompt.
    ///
    /// That predates auto-replace: it needed only route two, which has
    /// existed throughout, and root §3 has claimed "copy only" for terminals
    /// the whole time. The guard was in the wrong place, not missing.
    ///
    /// Ungated by `autoReplace`, because pasting into a prompt is wrong
    /// whatever the setting says.
    @Test("a terminal captured through accessibility is never pasted into either")
    func aTerminalCapturedAtRungFiveIsNotPastedInto() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let ax = liveTarget()
            ax.settable = false  // Terminal: AXValue not settable, so route one declines
            ax.editable = true  // but AXTextArea is an editable role, so route two ran
            let keystroke = FakeKeystroke()

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard,
                system: FakeSystem(
                    frontmost: FrontmostApp(
                        pid: 501, bundleID: "com.apple.Terminal", appVersion: "1.0"))
            ).apply(
                "the rewrite",
                to: snapshot(bundleID: "com.apple.Terminal"),
                autoReplace: false, keepOutOfHistory: false)

            #expect(keystroke.pastes == 0, "no ⌘V at a shell prompt")
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
            if case .heldForManualCopy(cause: .notPasted, _) = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// The list was written from memory and one entry was wrong —
    /// `io.alacritty` for an app whose `Info.plist` declares `org.alacritty`,
    /// which meant an Alacritty user got a rewrite pasted at their prompt.
    /// One wrong entry means the rest were produced the same way, so these
    /// are the ones since checked against a real `Info.plist`:
    /// Terminal, Ghostty and WezTerm read locally with `defaults read`,
    /// Alacritty from the official repository plist.
    ///
    /// **iTerm2, Warp, kitty and Hyper remain unverified** and are not listed
    /// here, because a test asserting a value nobody checked would launder a
    /// guess into an assertion.
    @Test(
        "the verified terminal identifiers are refused",
        arguments: [
            "com.apple.Terminal", "com.mitchellh.ghostty",
            "com.github.wez.wezterm", "org.alacritty",
        ])
    func verifiedTerminalIdentifiersAreRefused(bundleID: String) throws {
        withPrivatePasteboard { pasteboard in
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()

            _ = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(bundleID: bundleID),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0, "\(bundleID) must never be pasted into")
        }
    }

    /// Named for the mechanism, not the list. A terminal is the one case no
    /// observation can catch: ⌘V *succeeds* there — it inserts at the shell
    /// prompt — so the confirming re-read would see the selection gone and
    /// call it a replacement, while a rewrite ending in a newline has just
    /// run as a command. Everything that merely *ignores* a paste, a PDF
    /// included, is caught by the confirmation and needs no entry.
    @Test("an app that inserts a paste rather than replacing it is never pasted into")
    func anAppThatInsertsRatherThanReplacesIsRefused() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"  // the re-read would have agreed
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(bundleID: "com.apple.Terminal"),
                autoReplace: true, keepOutOfHistory: true)

            #expect(keystroke.pastes == 0)
            #expect(clipboard.attempts == 0, "refused before even the re-read")
            #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
            if case .heldForManualCopy(cause: .notPasted, _) = outcome {} else {
                Issue.record("expected the rewrite to be held, got \(outcome)")
            }
        }
    }

    /// What the switch is for. Off means exactly today's behaviour, including
    /// the durable write — a user who turns it off is asking to paste by
    /// hand, and `copiedOnly` is the promise that the text is there to paste.
    @Test("with auto-replace off a clipboard capture is copy-only, exactly as before")
    func autoReplaceOffKeepsTheOldCopyOnlyBehaviour() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()

            let outcome = service(
                FakeAccessibility(), keystroke: keystroke, pasteboard: pasteboard,
                clipboard: clipboard
            ).apply(
                "the rewrite", to: viaClipboardSnapshot(),
                autoReplace: false, keepOutOfHistory: false)

            #expect(keystroke.pastes == 0)
            #expect(clipboard.attempts == 0, "no re-read, so no extra ⌘C")
            #expect(pasteboard.string(forType: .string) == "the rewrite", "durably, as promised")
            #expect(
                outcome
                    == .copiedOnly(
                        cause: .unverifiable, reason: "the target could not be verified"))
        }
    }

    /// A rung-9 snapshot carries no range and no real element — `element` is
    /// the *application* element, which is not a thing anyone can paste into.
    /// `compare` therefore returns `.unknown` the moment it sees a nil range,
    /// and `validate` turns that into `.unverifiable`.
    ///
    /// **Route two is now reachable for these, but only through
    /// `pasteUnverifiable`**, which re-reads the selection first and refuses
    /// the apps where a paste inserts rather than replaces. This test is the
    /// other side of that gate: with auto-replace *off*, the old refusal
    /// stands exactly, and the ordinary editability path can still never be
    /// reached by a clipboard capture.
    ///
    /// The fixture deliberately makes every *other* signal say yes: the
    /// element matches, and `isEditable` is true. The nil range alone has to
    /// be enough, because it is the only one of the three that a rung-9
    /// snapshot always has.
    @Test("a clipboard-derived snapshot never reaches the ordinary paste route")
    func clipboardCaptureNeverReachesRouteTwo() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = false  // route one declines
            ax.editable = true  // and accessibility would call the target editable
            let keystroke = FakeKeystroke()

            // Exactly what `SelectionCoordinator.readViaClipboard` builds.
            let viaClipboard = TargetSnapshot(
                pid: 501,
                bundleID: "com.example.terminal",
                appVersion: "1.0",
                element: AXUIElementCreateApplication(501),
                text: "the original",
                range: nil,
                role: nil,
                isEditable: false,
                isRangeDerived: false,
                viaClipboard: true
            )

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: viaClipboard, autoReplace: false, keepOutOfHistory: false)

            #expect(keystroke.pastes == 0, "no ⌘V is posted at a shell prompt")
            #expect(ax.writes.isEmpty)
            #expect(
                outcome
                    == .copiedOnly(
                        cause: .unverifiable, reason: "the target could not be verified"))
        }
    }

    /// Route one. The app performs the replacement itself, so it lands in one
    /// undo step, respects the field's own formatting rules, and never
    /// touches the clipboard.
    ///
    /// **And when the write reports success we stop.** No confirming read:
    /// the only thing a confirmation could do if it came back inconclusive is
    /// fall through and paste as well, and a false negative there inserts the
    /// rewrite twice. A duplicated paragraph is unrecoverable; a rewrite that
    /// quietly did not land is visible and the user can press the hotkey
    /// again. The asymmetry decides it — which is what `keystroke.pastes == 0`
    /// below is really pinning, and why it is not a throwaway assertion.
    @Test("a still-matching target is replaced through the accessibility write")
    func matchingTargetIsReplacedInPlace() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .replaced)
            #expect(ax.writes == ["the rewrite"])
            #expect(keystroke.pastes == 0, "route one never chains into route two")
            #expect(
                pasteboard.string(forType: .string) == "the user's clipboard",
                "route one does not touch the clipboard at all"
            )
        }
    }

    // MARK: - Revalidation
    //
    // A rewrite takes seconds, and a local model on a long selection can take
    // well over ten. Three seconds is already enough to click into another
    // window, scroll, select something else, or switch apps. Writing into
    // whatever happens to be focused when generation finishes means
    // overwriting text the user never offered us, in an app they may not be
    // looking at — and a synthetic paste lands in the target's undo stack as
    // an ordinary edit with no hint of where it came from, so they may not
    // even know what to undo.

    @Test("a different process being frontmost refuses the write")
    func refusesWhenAnotherProcessIsFrontmost() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard,
                system: FakeSystem(
                    frontmost: FrontmostApp(
                        pid: 999, bundleID: "com.example.other", appVersion: "1.0"
                    )
                )
            ).apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .targetChanged, reason: "the target app is no longer frontmost"))
            #expect(ax.writes.isEmpty, "the other app's document is untouched")
            #expect(keystroke.pastes == 0)
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    @Test("the selection having moved refuses the write")
    func refusesWhenTheRangeHasMoved() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.range = CFRange(location: 40, length: 12)  // the user scrolled and reselected
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .targetChanged, reason: "the selection changed"))
            #expect(ax.writes.isEmpty)
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    @Test("the selected text having changed refuses the write")
    func refusesWhenTheTextHasChanged() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.selected = "something else"  // same place, different content
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .targetChanged, reason: "the selection changed"))
            #expect(ax.writes.isEmpty)
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    @Test("a different focused element refuses the write")
    func refusesWhenFocusMovedToAnotherElement() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.focused = AXUIElementCreateApplication(777)  // a different element entirely
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .targetChanged, reason: "focus moved to another element"))
            #expect(ax.writes.isEmpty)
        }
    }

    /// Focus can move inside the same element tree while a rewrite is in
    /// flight, so the secure check is not a capture-time-only concern.
    @Test("a target that has become a password field refuses the write")
    func refusesWhenTheTargetBecameSecure() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.subrole = "AXSecureTextField"
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .secureField, reason: "the target is a secure field"))
            #expect(ax.writes.isEmpty)
        }
    }

    /// `unknown` is not `matches`. "The app stopped answering" is genuinely
    /// different from "the selection changed", and the consequence is worth
    /// stating plainly: a selection captured through the clipboard path has no
    /// range and no readable text, so there is no route by which to prove
    /// anything, and those apps always end in copy-only. If we could not read
    /// the app we cannot prove where a paste would land.
    @Test("a snapshot with nothing to validate against is refused rather than assumed safe")
    func unknownIsNotAMatch() throws {
        withPrivatePasteboard { pasteboard in
            let ax = FakeAccessibility()  // the app answers nothing
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(range: nil), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .unverifiable, reason: "the target could not be verified"))
            #expect(ax.writes.isEmpty)
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    /// A snapshot whose text came from `AXStringForRange` is refused *before*
    /// the validator runs, and the earliness is the point: nobody should
    /// later be able to read a passing validator as evidence that such a
    /// write would be safe.
    ///
    /// Revalidation is structurally unable to catch the Chromium off-by-one
    /// here. `compare` mirrors the capture chain, so for this snapshot it
    /// would re-read through the *same* shifted range, get the *same* shifted
    /// string, and confirm a match with itself. The identity check detects
    /// *change*; the reading was wrong from the start.
    ///
    /// Losing automatic replacement here is the correct trade. A rewrite the
    /// user has to paste is an inconvenience. A rewrite of text that was off
    /// by one character, written over a selection that was not quite what we
    /// read, is silent corruption of their document.
    @Test("a range-derived snapshot is never written, even when everything still matches")
    func rangeDerivedSnapshotForcesCopyOnly() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = true
            let keystroke = FakeKeystroke()

            // Everything a validator could check still agrees: same process,
            // same element, same range, same text.
            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(isRangeDerived: true), autoReplace: false, keepOutOfHistory: false)

            #expect(
                outcome
                    == .copiedOnly(
                        cause: .rangeDerived,
                        reason: "the selection was reconstructed from a range and cannot be verified"
                    ))
            #expect(ax.writes.isEmpty, "no write, on either route")
            #expect(keystroke.pastes == 0)
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    /// The refusal is ahead of the validator, not merely somewhere before the
    /// write: if it sat after, a future edit could read "validator passed" as
    /// permission.
    @Test("the range-derived refusal happens before the validator is consulted")
    func rangeDerivedRefusalPrecedesValidation() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()

            _ = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(isRangeDerived: true), autoReplace: false, keepOutOfHistory: false)

            #expect(ax.focusResolutions == 0, "the validator never ran")
            #expect(ax.textReads == 0)

            // The positive control, which this test had none of. Both zeroes
            // above read identically when `apply` did nothing at all —
            // refused earlier for an unrelated reason, or never reached. What
            // makes them mean "the flag suppressed the validator" is the same
            // fixture with the flag off driving it. Deliberately *not* an
            // assertion on the outcome: that is the subject of the test above,
            // and repeating it would make one regression look like two.
            let readable = liveTarget()
            _ = service(readable, keystroke: FakeKeystroke(), pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(isRangeDerived: false), autoReplace: false, keepOutOfHistory: false)
            #expect(readable.focusResolutions > 0, "the validator runs when it is allowed to")
        }
    }

    /// An app that answers accessibility reads but is neither settable nor
    /// editable: static text, a rendered PDF, terminal output. There is no
    /// editable buffer behind the selection, and copy-only is the correct
    /// behaviour there rather than a bug to fix.
    @Test("a target that is neither settable nor editable is copy-only, with no paste attempted")
    func nonEditableTargetIsCopyOnly() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            ax.settable = false
            ax.editable = false
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(
                outcome
                    == .copiedOnly(
                        cause: .notEditable, reason: "the target would not accept the write"))
            #expect(keystroke.pastes == 0, "no paste into something with no editable buffer")
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    // MARK: - Held for manual copy
    //
    // `copiedOnly` overwrites the clipboard by definition. That is an
    // acceptable, reported trade when what it overwrites is something a
    // clipboard manager recorded and the user can get back. It is not
    // acceptable when the clipboard holds something we could not even
    // capture, because then the overwrite is unrecoverable. So when Everest
    // can neither write to the target nor safely borrow the clipboard, it
    // touches nothing and lets the user decide.

    @Test("nothing is touched when the target refuses the write and the clipboard cannot be borrowed")
    func heldForManualCopyWhenNeitherRouteIsSafe() throws {
        withPrivatePasteboard { pasteboard in
            let huge = Data(repeating: 0xCD, count: 20 * 1024 * 1024)
            let item = NSPasteboardItem()
            item.setData(huge, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let changeCountBefore = pasteboard.changeCount

            let ax = liveTarget()
            ax.selected = "something else"  // the selection moved: no write route
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(
                outcome
                    == .heldForManualCopy(
                        cause: .clipboardTooLarge,
                        reason:
                            "the selection changed, and your clipboard is too large to put back"
                    ))
            #expect(ax.writes.isEmpty)
            #expect(keystroke.pastes == 0)
            #expect(pasteboard.changeCount == changeCountBefore, "nothing was written")
            #expect(
                pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge,
                "the user's oversized clipboard survives, and the choice to overwrite is theirs"
            )
        }
    }

    /// The contrast that keeps the test above honest: an ordinary clipboard
    /// is still overwritten, because that is what `copiedOnly` promises.
    @Test("an ordinary clipboard is still overwritten, because copiedOnly promises that")
    func ordinaryClipboardIsStillOverwritten() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("something small", forType: .string)

            let ax = liveTarget()
            ax.selected = "something else"
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .targetChanged, reason: "the selection changed"))
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    /// A password field can take focus between capture and apply. While
    /// secure input is on, synthetic keystrokes are not delivered anyway, so
    /// the paste route would fail silently rather than visibly.
    @Test("secure input turning on between capture and apply refuses the write")
    func refusesWhenSecureInputTurnedOnBeforeApply() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            let system = FakeSystem(
                secureInputEnabled: true,
                frontmost: FrontmostApp(
                    pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
            )

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, system: system
            ).apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .secureField, reason: "a password field has focus"))
            #expect(ax.writes.isEmpty)
            #expect(keystroke.pastes == 0)
        }
    }

    /// The user can revoke Accessibility mid-rewrite.
    @Test("Accessibility permission revoked between capture and apply refuses the write")
    func refusesWhenAccessibilityRevokedBeforeApply() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            let system = FakeSystem(
                accessibilityTrusted: false,
                frontmost: FrontmostApp(
                    pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
            )

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, system: system
            ).apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .noAccessibility, reason: "Accessibility permission was revoked"))
            #expect(ax.writes.isEmpty)
        }
    }

    // MARK: - Route two
    //
    // Reached when an app answers accessibility reads but will not accept the
    // write. Real web-based editors do this. It is only ever reached after
    // the validator has passed, which is what makes a synthetic paste
    // defensible at all: milliseconds earlier we proved the exact text we
    // captured is still selected in the exact element we captured it from, so
    // the paste replaces *that selection*. It is never a paste at the current
    // cursor, and an app we could not read never reaches this code.

    @Test("an app that will not accept the write is pasted into, and the clipboard is put back")
    func pasteRouteReplacesThenRestoresTheClipboard() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = liveTarget()
            ax.settable = false  // answers reads, refuses the write
            let keystroke = FakeKeystroke()
            keystroke.onPaste = { [weak ax] in
                // A paste collapses the selection to a caret and moves the
                // insertion point, so both the range and the text change.
                ax?.selected = ""
                ax?.range = CFRange(location: 14, length: 0)
            }

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .replaced)
            #expect(keystroke.pastes == 1)
            #expect(ax.writes.isEmpty, "route one was not available")
            #expect(pasteboard.string(forType: .string) == "the user's clipboard")
        }
    }

    /// Budget exhausted with the selection still intact means not consumed,
    /// and we fall back rather than claim an edit the user cannot see.
    @Test("a paste the target never consumed is reported as copy-only, not as a replacement")
    func unconsumedPasteIsNotClaimedAsAReplacement() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = liveTarget()
            ax.settable = false
            let keystroke = FakeKeystroke()  // the target ignores the paste

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(keystroke.pastes == 1)
            #expect(outcome == .copiedOnly(cause: .pasteNotConsumed, reason: "the target did not accept the paste"))
            #expect(pasteboard.string(forType: .string) == "the rewrite")
        }
    }

    /// The `canBorrow` check has to be at the front. By the time you are in
    /// `restoreIfUnchanged` the user's bytes are already gone from your copy
    /// and off the pasteboard, and there is nothing left to be careful with.
    @Test("route two is abandoned before the scratch write when the clipboard cannot be borrowed")
    func pasteRouteHeldWhenTheClipboardCannotBeBorrowed() throws {
        withPrivatePasteboard { pasteboard in
            let huge = Data(repeating: 0xEF, count: 20 * 1024 * 1024)
            let item = NSPasteboardItem()
            item.setData(huge, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let changeCountBefore = pasteboard.changeCount

            let ax = liveTarget()
            ax.settable = false
            let keystroke = FakeKeystroke()

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(
                outcome
                    == .heldForManualCopy(
                        cause: .clipboardTooLarge,
                        reason:
                            "the target would not accept the write, and your clipboard is too large to put back"
                    ))
            #expect(keystroke.pastes == 0, "no keystroke was posted")
            #expect(pasteboard.changeCount == changeCountBefore)
            #expect(pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge)
        }
    }

    /// A user who switches away clears the selection by losing focus, and
    /// that would otherwise read as a successful paste.
    @Test("the target app ceasing to be frontmost during observation is not a successful paste")
    func switchingAwayDuringObservationIsNotAConsumedPaste() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = liveTarget()
            ax.settable = false
            let system = FakeSystem(
                frontmost: FrontmostApp(
                    pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
            )
            let keystroke = FakeKeystroke()
            keystroke.onPaste = { [weak ax] in
                ax?.selected = ""
                ax?.range = CFRange(location: 14, length: 0)
                system.frontmost = FrontmostApp(
                    pid: 999, bundleID: "com.example.other", appVersion: "1.0")
            }

            let outcome = service(
                ax, keystroke: keystroke, pasteboard: pasteboard, system: system
            ).apply("the rewrite", to: snapshot(), autoReplace: false, keepOutOfHistory: false)

            #expect(outcome == .copiedOnly(cause: .pasteNotConsumed, reason: "the target did not accept the paste"))
        }
    }

}
