import AppKit
import ApplicationServices
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "replacement.validator"
)

/// Proves, immediately before a write, that the world still matches the
/// snapshot we captured.
///
/// A rewrite takes seconds. Three seconds is enough time to click into another
/// window, scroll, select something else, or switch apps. Writing into whatever
/// happens to be focused at that point would overwrite text the user never
/// offered us, in an app they may not even be looking at. There is no undo for
/// that from our side and often none from theirs either, because a synthetic
/// paste lands in the target's undo stack as an ordinary edit with no hint of
/// where it came from.
///
/// So: four identities have to hold. Same process in front, same focused
/// element, same range, same text. Any doubt at all resolves to "do not write".
@MainActor
enum TargetValidator {

    enum Verdict: Equatable {
        case ok
        case mismatch(reason: String)
    }

    /// How the live selection compares to the snapshot.
    ///
    /// Three values rather than a Bool because "the app stopped answering" is
    /// genuinely different from "the selection changed", and the two callers
    /// want opposite things from the unknown case. Validation treats unknown as
    /// a refusal. Paste observation treats unknown as "keep looking".
    enum SelectionState {
        case matches
        case differs
        case unknown
    }

    /// The full pre-write check.
    ///
    /// Note what is *not* here: an age limit. `capturedAt` is on the snapshot
    /// but is deliberately not compared against a deadline. A local model on a
    /// long selection can take well over ten seconds, and a user who has not
    /// touched anything in that time is still entitled to their rewrite. The
    /// four identity checks are what make the write safe; a timeout would only
    /// add a second way to fail while removing none of the ways to be wrong.
    /// Do not add one.
    static func validate(_ snapshot: TargetSnapshot) -> Verdict {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return .mismatch(reason: "No app is in front")
        }
        guard front.processIdentifier == snapshot.pid else {
            return .mismatch(reason: "A different app is in front now")
        }
        guard let focused = AXSelectionAdapter.focusedElement(pid: snapshot.pid) else {
            return .mismatch(reason: "The text is no longer focused")
        }
        // CFEqual, not ===. Two AXUIElement references obtained at different
        // moments for the same interface object are equal but not identical,
        // so pointer comparison would report a mismatch every single time.
        guard CFEqual(focused, snapshot.element) else {
            return .mismatch(reason: "Focus moved to a different field")
        }
        // Re-checked here and not only at capture. A password field can take
        // focus inside the same element tree while a rewrite is in flight.
        if AXSelectionAdapter.isSecureElement(focused) {
            return .mismatch(reason: "A password field is focused")
        }

        switch compare(snapshot, against: focused) {
        case .matches:
            return .ok
        case .differs:
            return .mismatch(reason: "The selected text changed")
        case .unknown:
            return .mismatch(reason: "The selection could not be confirmed")
        }
    }

    /// Compares the live selection of `element` with what the snapshot recorded.
    ///
    /// The comparison deliberately mirrors the capture chain, route for route.
    /// An app whose text arrived through `AXStringForRange` reports an empty
    /// `AXSelectedText`, so a naive string comparison against the snapshot
    /// would fail on every such app and no rewrite would ever be written back.
    ///
    /// `unknown` is returned when neither route answers. For a selection
    /// captured through the clipboard there is no route at all, which means
    /// those apps always end in `.copiedOnly`. That is correct and intended: if
    /// we could not read the app, we cannot prove where a paste would land, and
    /// a rewrite on the clipboard is a far better outcome than a paragraph
    /// destroyed somewhere off screen.
    static func compare(_ snapshot: TargetSnapshot, against element: AXUIElement) -> SelectionState {
        if let expected = snapshot.range {
            guard let current = AXSelectionAdapter.copyRange(
                element, kAXSelectedTextRangeAttribute)
            else { return .unknown }
            if current.location != expected.location || current.length != expected.length {
                return .differs
            }
        }

        if let current = AXSelectionAdapter.copyString(element, kAXSelectedTextAttribute),
           !current.isEmpty
        {
            // Exact comparison. No trimming, no case folding, no whitespace
            // normalisation. A selection that differs from the snapshot by one
            // trailing space is a different selection, and treating it as the
            // same one is how a rewrite ends up shifted by a character.
            return current == snapshot.text ? .matches : .differs
        }

        if let expected = snapshot.range,
           let viaRange = AXSelectionAdapter.stringForRange(element, expected)
        {
            return viaRange == snapshot.text ? .matches : .differs
        }

        return .unknown
    }
}
