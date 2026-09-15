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
        isRangeDerived: Bool = false
    ) -> TargetSnapshot {
        TargetSnapshot(
            pid: pid,
            bundleID: "com.example.editor",
            appVersion: "1.0",
            element: AXUIElementCreateApplication(501),
            text: text,
            range: range,
            role: "AXTextArea",
            isEditable: true,
            isRangeDerived: isRangeDerived
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
        consumptionBudget: Duration = .milliseconds(40),
        system: FakeSystem = FakeSystem(
            frontmost: FrontmostApp(pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
        )
    ) -> ReplacementService {
        ReplacementService(
            system: system,
            accessibility: ax,
            keystroke: keystroke,
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

    /// The precondition for auto-replace, pinned rather than reasoned about.
    ///
    /// A rung-9 snapshot carries no range and no real element — `element` is
    /// the *application* element, which is not a thing anyone can paste into.
    /// `compare` therefore returns `.unknown` the moment it sees a nil range,
    /// `validate` turns that into `.unverifiable`, and `apply` hands off long
    /// before the editability check. Terminals, PDFs and Google Docs are all
    /// rung 9, so nothing that reaches the editability check can be one.
    ///
    /// The fixture deliberately makes every *other* signal say yes: the
    /// element matches, and `isEditable` is true. The nil range alone has to
    /// be enough, because it is the only one of the three that a rung-9
    /// snapshot always has.
    @Test("a clipboard-derived snapshot never reaches route two")
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
                isRangeDerived: false
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
