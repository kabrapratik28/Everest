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

    private func service(
        _ ax: FakeAccessibility,
        keystroke: FakeKeystroke,
        pasteboard: NSPasteboard,
        system: FakeSystem = FakeSystem(
            frontmost: FrontmostApp(pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
        )
    ) -> ReplacementService {
        ReplacementService(
            system: system,
            accessibility: ax,
            keystroke: keystroke,
            pasteboard: pasteboard,
            // Small but real. The budget is a ceiling on observation, not a
            // delay: a consumed paste returns on the first poll, and an
            // unconsumed one always exhausts, so both assertions are
            // deterministic and neither costs the suite 450 ms.
            consumptionBudget: .milliseconds(40),
            consumptionPollInterval: .milliseconds(4)
        )
    }

    /// Route one. The app performs the replacement itself, so it lands in one
    /// undo step, respects the field's own formatting rules, and never
    /// touches the clipboard.
    @Test("a still-matching target is replaced through the accessibility write")
    func matchingTargetIsReplacedInPlace() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let outcome = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot())

            #expect(outcome == .replaced)
            #expect(ax.writes == ["the rewrite"])
            #expect(keystroke.pastes == 0, "route one never chains into route two")
            #expect(
                pasteboard.string(forType: .string) == "the user's clipboard",
                "route one does not touch the clipboard at all"
            )
        }
    }

    /// When the write reports success we stop. No confirming read: the only
    /// thing a confirmation could do if it came back inconclusive is fall
    /// through and paste as well, and a false negative there inserts the
    /// rewrite twice. A duplicated paragraph is unrecoverable; a rewrite that
    /// quietly did not land is visible and the user can press the hotkey
    /// again. The asymmetry decides it.
    @Test("a successful accessibility write is not verified and never chains into a paste")
    func successfulWriteDoesNotChainIntoAPaste() throws {
        withPrivatePasteboard { pasteboard in
            let ax = liveTarget()
            let keystroke = FakeKeystroke()

            _ = service(ax, keystroke: keystroke, pasteboard: pasteboard)
                .apply("the rewrite", to: snapshot())

            #expect(ax.writes.count == 1)
            #expect(keystroke.pastes == 0)
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
            ).apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot(range: nil))

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
                .apply("the rewrite", to: snapshot(isRangeDerived: true))

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
                .apply("the rewrite", to: snapshot(isRangeDerived: true))

            #expect(ax.focusResolutions == 0, "the validator never ran")
            #expect(ax.textReads == 0)
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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
            ).apply("the rewrite", to: snapshot())

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
            ).apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
                .apply("the rewrite", to: snapshot())

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
            ).apply("the rewrite", to: snapshot())

            #expect(outcome == .copiedOnly(cause: .pasteNotConsumed, reason: "the target did not accept the paste"))
        }
    }
}
