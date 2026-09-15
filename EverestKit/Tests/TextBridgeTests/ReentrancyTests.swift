import AppKit
import ApplicationServices
import Testing

@testable import TextBridge

/// The property under test is not "`observeConsumption` is synchronous". It
/// is **two transactions cannot interleave**, which is a behaviour and
/// therefore testable.
///
/// Blocking the main thread makes the interleaving unreachable in production
/// today, but that is an argument about scheduling, not about correctness,
/// and it evaporates the moment somebody adds a suspension point to silence
/// a 450 ms hitch. These tests force the interleaving directly through the
/// keystroke seam, which is exactly the window an `async` version would open.
@Suite("Re-entrancy")
struct ReentrancyTests {

    private func withPrivatePasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    private func snapshot() -> TargetSnapshot {
        TargetSnapshot(
            pid: 501, bundleID: "com.example.editor", appVersion: "1.0",
            element: AXUIElementCreateApplication(501),
            text: "the original", range: CFRange(location: 3, length: 12),
            role: "AXTextArea", isEditable: true, isRangeDerived: false
        )
    }

    private func liveTarget() -> FakeAccessibility {
        let ax = FakeAccessibility()
        ax.focused = AXUIElementCreateApplication(501)
        ax.selected = "the original"
        ax.range = CFRange(location: 3, length: 12)
        ax.settable = false  // route two, the only route that borrows
        return ax
    }

    /// Each test owns its registry rather than sharing the process-wide one.
    /// swift-testing runs suites in parallel, and a global keyed by
    /// pasteboard name is only accidentally safe: it relies on every borrow
    /// being released before AppKit recycles the name. Injection makes the
    /// suite order-independent by construction instead.
    private func service(
        _ ax: FakeAccessibility, _ keystroke: FakeKeystroke, _ pasteboard: NSPasteboard,
        _ borrow: PasteboardBorrow
    ) -> ReplacementService {
        ReplacementService(
            system: FakeSystem(
                frontmost: FrontmostApp(
                    pid: 501, bundleID: "com.example.editor", appVersion: "1.0")
            ),
            accessibility: ax,
            keystroke: keystroke,
            pasteboard: pasteboard,
            borrow: borrow,
            consumptionBudget: .milliseconds(40),
            consumptionPollInterval: .milliseconds(4)
        )
    }

    /// The mechanism, spelled out: the inner transaction snapshots **our own
    /// scratch text** as if it were the user's clipboard, and later restores
    /// that. Every `changeCount` check passes, because from each
    /// transaction's point of view nothing went wrong. The user's real
    /// clipboard is gone, replaced by a rewrite fragment.
    @Test("a second rewrite starting mid-paste cannot nest, and the user's clipboard survives")
    func aSecondRewriteMidPasteCannotNest() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            let borrow = PasteboardBorrow()
            let second = service(ax, FakeKeystroke(), pasteboard, borrow)
            let nested = Box<ReplaceOutcome>()

            keystroke.onPaste = {
                // A second ⌘I arrives while the first transaction is open,
                // between `writeTransient` and `restoreIfUnchanged`.
                nested.value = second.apply("the second rewrite", to: self.snapshot())
                // Then the first paste lands.
                ax.selected = ""
                ax.range = CFRange(location: 14, length: 0)
            }

            let first = service(ax, keystroke, pasteboard, borrow)
                .apply("the rewrite", to: snapshot())

            #expect(first == .replaced)
            #expect(
                nested.value
                    == ReplaceOutcome.heldForManualCopy(
                        cause: .clipboardBusy,
                        reason:
                            "the target would not accept the write, and another rewrite is using the clipboard"
                    ))
            #expect(
                pasteboard.string(forType: .string) == "the user's clipboard",
                "the user's real clipboard, not a rewrite fragment"
            )
        }
    }

    /// Both halves of the app borrow through the same type, so the exclusion
    /// has to hold across them, not just replacement against replacement.
    @Test("a capture cannot borrow the clipboard while a replacement holds it")
    func aCaptureCannotBorrowDuringAReplacement() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = liveTarget()
            let keystroke = FakeKeystroke()
            let copyKeystroke = FakeCopyKeystroke()
            let captured = Box<String>()
            let borrow = PasteboardBorrow()

            keystroke.onPaste = {
                let adapter = ClipboardSelectionAdapter(
                    pasteboard: pasteboard,
                    keystroke: copyKeystroke,
                    borrow: borrow,
                    copyBudget: .milliseconds(40),
                    settleBudget: .milliseconds(20),
                    pollInterval: .milliseconds(4)
                )
                captured.value = adapter.copySelection(pid: 501)
                ax.selected = ""
                ax.range = CFRange(location: 14, length: 0)
            }

            _ = service(ax, keystroke, pasteboard, borrow).apply("the rewrite", to: snapshot())

            #expect(captured.value == nil)
            #expect(copyKeystroke.copies == 0, "no ⌘C posted into an open transaction")
            #expect(pasteboard.string(forType: .string) == "the user's clipboard")
        }
    }

    /// Rejected rather than queued. Waiting would deadlock: both transactions
    /// run on the main thread, so the second would block the first from ever
    /// finishing and releasing.
    @Test("a second borrow of the same pasteboard is refused while the first is open")
    func aSecondBorrowIsRefused() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let borrow = PasteboardBorrow()
            let outer = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(outer.snapshot())

            let inner = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(inner.snapshot() == false)
            #expect(inner.canBorrow == false)
            #expect(inner.fidelity == .notTaken, "no snapshot was taken, and none was lost")
            #expect(inner.restoreIfUnchanged() == false)

            // The first transaction is unaffected and still works.
            outer.writeTransient("scratch")
            #expect(outer.restoreIfUnchanged())
            #expect(pasteboard.string(forType: .string) == "the user's clipboard")
        }
    }

    /// The borrow has to come back, or the first rewrite of the session
    /// poisons every one after it.
    @Test("the borrow is released once the transaction is finished")
    func theBorrowIsReleasedAfterwards() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let borrow = PasteboardBorrow()
            let first = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(first.snapshot())
            first.writeTransient("scratch")
            #expect(first.restoreIfUnchanged())

            let second = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(second.snapshot(), "the borrow came back")
            #expect(second.canBorrow)
        }
    }

    /// Two different pasteboards never contend, which is what keeps this
    /// suite safe to run in parallel with the rest.
    @Test("borrows on different pasteboards do not contend")
    func differentPasteboardsDoNotContend() {
        withPrivatePasteboard { one in
            withPrivatePasteboard { two in
                let borrow = PasteboardBorrow()
                let a = PasteboardTransaction(pasteboard: one, borrow: borrow)
                let b = PasteboardTransaction(pasteboard: two, borrow: borrow)
                #expect(a.snapshot())
                #expect(b.snapshot())
                // Finish both explicitly: a test that leans on `deinit` to
                // release a process-wide lock is the exact bug this suite
                // exists to prevent.
                #expect(a.restoreIfUnchanged())
                #expect(b.restoreIfUnchanged())
            }
        }
    }
}

final class Box<T> {
    var value: T?
}
