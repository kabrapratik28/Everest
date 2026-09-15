import AppKit
import ApplicationServices
import Testing

@testable import TextBridge

/// Four fixes have shipped to the capture-and-replace path today and every
/// one was verified by a suite that agreed with the code and disagreed with
/// the user. The trail is what makes the fifth diagnosable from a log rather
/// than from three people re-reading the source.
///
/// These tests assert the *recorded trail*, not that a logger was called.
/// A trail with a hole in it is worth nothing on the day it is needed, and
/// the hole is invisible to any test that only checks the mechanism.
@Suite("Trace")
struct TraceTests {

    private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    /// The Sublime path end to end: rung 9, a validator refusal that is not a
    /// real refusal, the override entering, the re-read agreeing, the paste
    /// confirmed. Every step that was invisible while we got this wrong three
    /// times running.
    @Test("the rung-9 paste path records every decision that led to the outcome")
    func theRungNinePastePathIsFullyTraced() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's own clipboard", forType: .string)

            let ax = FakeAccessibility()
            ax.focused = testElement(pid: 777)  // Sublime resolves a window
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let keystroke = FakeKeystroke()
            keystroke.onPaste = { clipboard.result = nil }
            let trace = FakeTrace()

            let service = ReplacementService(
                system: FakeSystem(
                    frontmost: FrontmostApp(pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0")
                ),
                accessibility: ax,
                keystroke: keystroke,
                clipboard: clipboard,
                pasteboard: pasteboard,
                consumptionBudget: .milliseconds(40),
                consumptionPollInterval: .milliseconds(4)
            )
            service.trace = trace

            _ = service.apply(
                "the rewrite",
                to: TargetSnapshot(
                    pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0",
                    element: AXUIElementCreateApplication(501),
                    text: "the original", range: nil, role: nil,
                    isEditable: false, isRangeDerived: false, viaClipboard: true
                ),
                autoReplace: true, keepOutOfHistory: true)

            #expect(
                trace.events == [
                    .writeRefused(.unverifiable),
                    .pasteOverrideEntered,
                    .reRead(matched: true),
                    .pasteConfirmed(true),
                    .outcome(.replaced),
                ])
        }
    }

    /// The branch we could not see. When the override does not run, the trail
    /// has to say which condition stopped it — that is the single fact three
    /// rounds of source-reading failed to establish.
    @Test("an override that does not run records why it did not")
    func aSkippedOverrideRecordsItsReason() throws {
        withPrivatePasteboard { pasteboard in
            let ax = FakeAccessibility()
            ax.focused = testElement(pid: 777)
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let trace = FakeTrace()

            let service = ReplacementService(
                system: FakeSystem(
                    frontmost: FrontmostApp(pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0")
                ),
                accessibility: ax,
                keystroke: FakeKeystroke(),
                clipboard: clipboard,
                pasteboard: pasteboard
            )
            service.trace = trace

            _ = service.apply(
                "the rewrite",
                to: TargetSnapshot(
                    pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0",
                    element: AXUIElementCreateApplication(501),
                    text: "the original", range: nil, role: nil,
                    isEditable: false, isRangeDerived: false, viaClipboard: true
                ),
                autoReplace: false, keepOutOfHistory: false)

            #expect(trace.events.contains(.pasteOverrideSkipped(.autoReplaceOff)))
        }
    }

    /// The property that makes the trail worth keeping: **every** exit
    /// records its outcome, not the ones someone remembered. Driven across
    /// four genuinely different routes, because a hole is invisible until
    /// the day it is read — and by then the branch that took it is the one
    /// you are trying to find.
    @Test(
        "every route out of apply records exactly one outcome",
        arguments: [Route.inPlace, .secure, .rangeDerived, .clipboardOverride])
    func everyRouteRecordsItsOutcome(route: Route) throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's clipboard", forType: .string)

            let ax = FakeAccessibility()
            ax.focused = AXUIElementCreateApplication(501)
            ax.selected = "the original"
            ax.range = CFRange(location: 3, length: 12)
            let clipboard = FakeClipboardCapture()
            clipboard.result = "the original"
            let trace = FakeTrace()
            var secureInput = false

            func inPlace(_ derived: Bool) -> TargetSnapshot {
                TargetSnapshot(
                    pid: 501, bundleID: "com.example.editor", appVersion: "1.0",
                    element: AXUIElementCreateApplication(501),
                    text: "the original", range: CFRange(location: 3, length: 12),
                    role: "AXTextArea", isEditable: true, isRangeDerived: derived,
                    viaClipboard: false)
            }
            var snapshot = inPlace(false)

            switch route {
            case .inPlace: break
            case .secure: secureInput = true
            case .rangeDerived: snapshot = inPlace(true)
            case .clipboardOverride:
                ax.focused = testElement(pid: 777)
                snapshot = TargetSnapshot(
                    pid: 501, bundleID: "com.sublimetext.4", appVersion: "1.0",
                    element: AXUIElementCreateApplication(501),
                    text: "the original", range: nil, role: nil,
                    isEditable: false, isRangeDerived: false, viaClipboard: true)
            }

            let service = ReplacementService(
                system: FakeSystem(
                    secureInputEnabled: secureInput,
                    frontmost: FrontmostApp(
                        pid: 501, bundleID: snapshot.bundleID, appVersion: "1.0")),
                accessibility: ax,
                keystroke: FakeKeystroke(),
                clipboard: clipboard,
                pasteboard: pasteboard,
                consumptionBudget: .milliseconds(20),
                consumptionPollInterval: .milliseconds(4)
            )
            service.trace = trace

            let outcome = service.apply(
                "the rewrite", to: snapshot, autoReplace: true, keepOutOfHistory: true)

            let recorded = trace.events.filter {
                if case .outcome = $0 { return true }
                return false
            }
            #expect(recorded == [.outcome(outcome)], "on route \(route)")
        }
    }

    enum Route: Equatable { case inPlace, secure, rangeDerived, clipboardOverride }

    /// Capture records which rung answered and the shape of what it produced,
    /// because `viaClipboard` and a nil range are what every branch below
    /// turns on, and neither is visible from the outcome alone.
    @Test("capture records the rung that answered and the shape of the snapshot")
    func captureRecordsTheRungAndShape() throws {
        let ax = FakeAccessibility()  // nothing at all, so rung 9 answers
        let clipboard = FakeClipboardCapture()
        clipboard.result = "opaque view text"
        let trace = FakeTrace()

        let coordinator = SelectionCoordinator(
            system: FakeSystem(),
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: [],
            manualAccessibilitySettle: .zero
        )
        coordinator.trace = trace

        _ = try coordinator.capture()

        #expect(
            trace.events == [
                .captured(
                    rung: .clipboard, length: 16, hasRange: false,
                    isEditable: false, isRangeDerived: false, role: nil)
            ])
    }

    /// A refusal is a decision too, and the one the user sees. Without it the
    /// trail stops exactly where the interesting thing happened.
    @Test("a capture refusal is recorded with its reason")
    func aCaptureRefusalIsRecorded() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.subrole = "AXSecureTextField"
        let trace = FakeTrace()

        let coordinator = SelectionCoordinator(
            system: FakeSystem(),
            accessibility: ax,
            clipboard: FakeClipboardCapture(),
            excludedBundleIDs: [],
            manualAccessibilitySettle: .zero
        )
        coordinator.trace = trace

        #expect(throws: CaptureError.secureField) { _ = try coordinator.capture() }
        #expect(trace.events == [.captureRefused(.secureField)])
    }
}
