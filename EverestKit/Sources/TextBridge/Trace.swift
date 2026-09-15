import Foundation
import OSLog

/// A content-free record of how one capture-and-replace decided what it did.
///
/// **Why this is permanent and not scaffolding.** Four fixes shipped to this
/// path in a day, and each was verified by a suite that agreed with the code
/// and disagreed with the user. The failure was never a missing test — it was
/// that a fixture and a mental model can be wrong in the same direction, and
/// then they agree. Nothing in the app could say which branch ran, so three
/// people read the source and drew the same wrong conclusion three times.
///
/// **Never content.** Root §6: no content in logs, and `OSLog` persists on
/// disk where the user cannot see it. Lengths, booleans, enum cases and
/// accessibility roles only — enough to locate any branch on this path, and
/// none of it the user's writing. A role is the app's own vocabulary
/// (`AXTextArea`), not theirs. **If a future event needs the text to be
/// useful, the event is wrong, not the rule.**
enum TraceEvent: Equatable {
    /// Which rung answered, and the shape of what it produced. Every branch
    /// below turns on `viaClipboard` and a nil range, and neither can be
    /// inferred from the outcome.
    case captured(
        rung: Rung, length: Int, hasRange: Bool, isEditable: Bool, isRangeDerived: Bool,
        role: String?)
    case captureRefused(CaptureError)

    /// The validator's verdict. `.focusMoved` and `.unverifiable` are the
    /// same fact for a rung-9 snapshot and only one of them sounds like it,
    /// which is precisely the confusion this exists to make visible.
    case writeRefused(TargetValidator.Refusal)

    /// Route one returned success and changed nothing — the Chromium case.
    /// Worth its own event because it is invisible from every other signal:
    /// the API said yes, the element still reports `settable`, and the only
    /// evidence is the read-back.
    case writeDropped

    /// A declared type that had no bytes of its own and was left out of the
    /// snapshot. Almost always a flavour AppKit re-advertises from the base
    /// types, and sometimes a promise whose provider refused — the two are
    /// indistinguishable, so the skip is an assumption, and this is what
    /// makes it visible when it turns out wrong.
    case snapshotSkippedType(String)

    case pasteOverrideEntered
    case pasteOverrideSkipped(OverrideSkip)
    case reRead(matched: Bool)
    case pasteConfirmed(Bool)
    case outcome(ReplaceOutcome)

    enum Rung: String, Equatable {
        case selectedText, stringForRange, clipboard
    }

    /// Why the rung-9 paste did not run. One case per condition, because
    /// "it did not fire" was the whole of what we knew for three rounds.
    enum OverrideSkip: String, Equatable {
        case autoReplaceOff, notClipboardCapture, refusalIsReal
    }
}

/// Injected so a test can assert the *trail*, not that a logger was called.
/// A trail with a hole in it is worth nothing on the day it is needed, and
/// no test of the mechanism can see the hole.
protocol Tracing: AnyObject {
    func record(_ event: TraceEvent)
}

/// The one production conformance. `OSLog` rather than `print` so the trail
/// survives the session and can be read back with
/// `log show --predicate 'subsystem == "…"' --last 5m`.
final class OSLogTrace: Tracing {
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Everest", category: "textbridge")

    func record(_ event: TraceEvent) {
        // `\(…, privacy: .public)` on purpose: everything here is already
        // content-free by construction, and the default redaction would
        // reduce the trail to `<private>` exactly when it is being read.
        log.debug("\(String(describing: event), privacy: .public)")
    }
}
