import Foundation
import RewriteCore

/// Everything the floating panel can be showing, as one closed set.
///
/// The panel is a pure function of this value. `FloatingPanelController` never
/// pokes at the view, and the view never reaches back into the coordinator: a
/// state goes in, a rendering comes out. That is what makes the panel testable
/// by eye (drive it through all ten cases from a debug menu) and what stops the
/// half-states that overlays usually rot into, where a spinner from a cancelled
/// transaction is still turning behind the result of the next one.
///
/// The cases are deliberately *outcomes*, not steps. `readOnly` and
/// `targetChanged` both mean "we have text and you must paste it yourself", but
/// they are separate cases because the user needs a different sentence in each
/// situation, and a single `couldNotApply(reason:)` case would push that
/// sentence out into the caller where it would be written three different ways.
enum PanelState: Equatable, Sendable {
    /// Reading the selection out of the frontmost app. Usually invisible: it
    /// lasts a few milliseconds unless an Accessibility call is slow.
    case capturing
    /// Model is loading or downloading. `nil` progress means the work is real
    /// but unmeasurable (a model load), which must render as an indeterminate
    /// bar rather than as 0%.
    case preparing(progress: Double?)
    /// Streaming. `text` is a cumulative snapshot, never a delta: see the
    /// repo-root AGENTS.md §3. This is the only case that arrives at token rate,
    /// and the only one the controller throttles.
    case generating(text: String)
    /// Writing the result back into the target app.
    case applying
    /// Replaced successfully. Terminal. The coordinator takes the panel down
    /// after a short delay; the panel never dismisses itself, because only the
    /// coordinator knows whether the transaction is really over.
    case success
    /// The target has no writable buffer (Terminal, a PDF, ordinary web prose),
    /// so the result went to the clipboard instead. `text` is shown so the user
    /// can read it without leaving the panel. Not an error: see repo-root
    /// AGENTS.md §6.
    case readOnly(text: String)
    /// We had a result, but the world moved underneath it: different app,
    /// different element, or the text changed while we were generating. The
    /// result is on the clipboard and we refuse to guess where it belongs.
    case targetChanged(text: String)
    /// The engine declined to produce output. Distinct from `error` because a
    /// refusal is a property of the input and retrying verbatim will refuse
    /// again, whereas an error is a property of the run.
    case refused(reason: String)
    /// Something broke. `reason` is already human-readable by the time it gets
    /// here; the panel does not translate error codes.
    case error(reason: String)
    /// We could neither write to the target nor safely borrow the clipboard, so
    /// we touched **nothing** and the panel is now the only place this rewrite
    /// exists.
    ///
    /// The case `readOnly` covers "no editable buffer, so we put it on the
    /// clipboard for you". This one covers the harder situation underneath it:
    /// the clipboard was holding something `PasteboardTransaction` could not
    /// snapshot and therefore could not restore, so writing the rewrite there
    /// would have destroyed it. Everest declines to make that trade on the
    /// user's behalf. `reason` says which of those situations occurred, in
    /// plain words, because "could not paste" tells the user nothing about what
    /// to do next.
    ///
    /// This is the one terminal state that must not be dismissed on a timer.
    /// See `autoDismisses`.
    case heldForManualCopy(text: String, reason: String)

    /// The ⌘⇧I list. Carries its presets rather than reading `AppSettings` from
    /// the view, so that the list on screen is the list the transaction will
    /// actually use even if settings change mid-flight.
    case stylePicker(presets: [Preset])
}

// MARK: - Presentation

/// How each state is *spoken*, not how it is coloured.
///
/// Every case here supplies an SF Symbol and a sentence. Nothing in the overlay
/// is allowed to distinguish success from failure by tint alone, because for a
/// user with deuteranopia a green check and a red cross at 24pt are the same
/// glyph in the same grey. The symbol carries the meaning, the words carry the
/// detail, and the colour is decoration that can be thrown away without loss.
/// If you add a case, you must fill in all of this; the compiler will make you.
extension PanelState {
    /// SF Symbol name. Filled variants only, so the shapes stay distinguishable
    /// at small sizes and under Increase Contrast.
    var symbolName: String {
        switch self {
        case .capturing: return "text.viewfinder"
        case .preparing: return "arrow.down.circle"
        case .generating: return "sparkles"
        case .applying: return "arrow.turn.down.left"
        case .success: return "checkmark.circle.fill"
        case .readOnly: return "doc.on.clipboard"
        case .targetChanged: return "exclamationmark.arrow.circlepath"
        // Deliberately not a clipboard glyph: nothing went to the clipboard,
        // and reusing `doc.on.clipboard` here would tell the user the opposite
        // of what happened.
        case .heldForManualCopy: return "tray.full.fill"
        case .refused: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .stylePicker: return "list.number"
        }
    }

    /// The short headline. Sentence case, no trailing punctuation.
    var title: String {
        switch self {
        case .capturing: return "Reading selection"
        case .preparing(let progress):
            if let progress { return "Preparing model \(Int((progress * 100).rounded()))%" }
            return "Preparing model"
        case .generating: return "Rewriting"
        case .applying: return "Replacing selection"
        case .success: return "Replaced"
        case .readOnly: return "Copied to clipboard"
        case .targetChanged: return "Target changed, copied instead"
        case .heldForManualCopy: return "Rewrite ready, nothing was changed"
        case .refused: return "Rewrite refused"
        case .error: return "Rewrite failed"
        case .stylePicker: return "Choose a style"
        }
    }

    /// The explanatory line under the headline, or `nil` when the headline says
    /// everything. Never contains the rewritten text; that renders separately so
    /// it can be selectable and monospaced-adjacent.
    var detail: String? {
        switch self {
        case .capturing, .generating, .applying, .success, .stylePicker:
            return nil
        case .preparing(let progress):
            return progress == nil ? "This happens once per model." : nil
        case .readOnly:
            return "This app has no editable text here, so nothing was replaced. Press ⌘V where you want it."
        case .targetChanged:
            return "The selection moved while this was generating, so nothing was replaced. Press ⌘V where you want it."
        case .heldForManualCopy(_, let reason):
            return reason
        case .refused(let reason):
            return reason
        case .error(let reason):
            return reason
        }
    }

    /// The result text to display, when there is one.
    var bodyText: String? {
        switch self {
        case .generating(let text), .readOnly(let text), .targetChanged(let text),
             .heldForManualCopy(let text, _):
            return text
        case .capturing, .preparing, .applying, .success, .refused, .error, .stylePicker:
            return nil
        }
    }

    /// True when the panel is the only place the rewrite exists, so the user
    /// needs an explicit Copy affordance to get it out.
    ///
    /// Only one state qualifies, and that is the point. `readOnly` and
    /// `targetChanged` already put the text on the clipboard, so offering Copy
    /// there would be a button that does nothing observable. Offering it here
    /// is the user consenting to overwrite a clipboard that Everest refused to
    /// overwrite for them.
    var offersManualCopy: Bool {
        if case .heldForManualCopy = self { return true }
        return false
    }

    /// Whether the coordinator may take this state down on a timer.
    ///
    /// This exists so the auto-dismiss rule is a property of the state rather
    /// than a condition written out at the call site. A coordinator that asks
    /// the state cannot get it wrong; a coordinator with
    /// `if case .success` or, worse, `if state.isTerminal` scattered through it
    /// will eventually get it wrong, and the way it gets it wrong is by
    /// throwing away the user's only copy of a rewrite.
    var autoDismisses: Bool {
        switch self {
        case .success, .readOnly, .targetChanged, .refused, .error:
            return true
        // Never. Dismissing this discards the rewrite: it is not on the
        // clipboard, it is not in the document, and it is not saved anywhere.
        case .heldForManualCopy:
            return false
        case .capturing, .preparing, .generating, .applying, .stylePicker:
            return false
        }
    }

    /// True while the transaction is still doing work the user can abandon.
    /// Drives whether a Cancel affordance is offered; Escape works regardless,
    /// because the key monitor is live for the whole presentation.
    var isCancellable: Bool {
        switch self {
        case .capturing, .preparing, .generating, .stylePicker:
            return true
        case .applying, .success, .readOnly, .targetChanged, .heldForManualCopy, .refused, .error:
            return false
        }
    }

    /// True when nothing further will happen on its own. Used by the controller
    /// to decide whether the streaming throttle is allowed to hold this state
    /// back, and it never is: a terminal state must land immediately or the
    /// panel can be left showing a spinner after the work has finished.
    var isTerminal: Bool {
        switch self {
        case .success, .readOnly, .targetChanged, .heldForManualCopy, .refused, .error:
            return true
        case .capturing, .preparing, .generating, .applying, .stylePicker:
            return false
        }
    }

    /// Only `generating` arrives at token rate, so only `generating` is eligible
    /// to be coalesced. See `FloatingPanelController.update(_:)`.
    var isStreaming: Bool {
        if case .generating = self { return true }
        return false
    }

    /// True when a determinate or indeterminate progress indicator belongs in
    /// the header. `preparing` and `generating` both spin; the difference is
    /// whether there is a fraction to show.
    var showsActivity: Bool {
        switch self {
        case .capturing, .preparing, .generating, .applying:
            return true
        case .success, .readOnly, .targetChanged, .refused, .error, .stylePicker:
            return false
        }
    }

    /// What VoiceOver reads for the panel as a whole.
    ///
    /// Assembled from the same strings that are drawn, rather than from a
    /// parallel set of accessibility-only copy, because a second set of strings
    /// is a second set of strings to forget to update. `generating` deliberately
    /// does not include the streaming text: VoiceOver would restart the
    /// utterance on every update and read nothing but the first three words over
    /// and over.
    var accessibilityLabel: String {
        switch self {
        case .generating:
            return "Rewriting in progress"
        case .readOnly(let text), .targetChanged(let text):
            return [title, detail, text].compactMap { $0 }.joined(separator: ". ")
        default:
            return [title, detail].compactMap { $0 }.joined(separator: ". ")
        }
    }
}
