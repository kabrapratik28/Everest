import RewriteCore

/// Everything the panel can be showing.
public enum PanelState: Equatable, Sendable {
    case capturing
    case preparing(progress: Double?)
    case generating(text: String)
    case applying
    case success
    case readOnly(text: String)
    case targetChanged(text: String)
    case refused(reason: String)
    case error(reason: String)
    case stylePicker(presets: [Preset])
    case heldForManualCopy(text: String, reason: String)
}

/// A `PanelState` with its payload stripped off.
///
/// This exists so the presentation rules can be checked for completeness. A
/// `switch` with no `default` makes the compiler demand words and an icon for a
/// new case, but nothing in the compiler can demand that a *test* covers it.
/// `kind` closes that loop: adding a case to `PanelState` forces a case here,
/// which grows `allCases`, which fails the coverage test until the new state is
/// sampled and checked like the other eleven.
public enum PanelStateKind: String, CaseIterable, Sendable {
    case capturing
    case preparing
    case generating
    case applying
    case success
    case readOnly
    case targetChanged
    case refused
    case error
    case stylePicker
    case heldForManualCopy
}

/// A keystroke the panel offers. Drawn as a keycap badge and the words beside
/// it, and the whole row is the clickable control — so the hint has to know
/// what it does, not just what it says.
public struct KeyHint: Equatable, Sendable {
    /// As the user reads it on the badge.
    public let keys: String
    /// What it does, in words.
    public let action: String
    /// What it does, as the same vocabulary the key map produces. Matching on
    /// `action` instead would break the first time someone rewords a label.
    public let performs: PanelKeyAction
}

public extension PanelState {
    /// The keystrokes worth telling the user about in this state.
    ///
    /// Derived rather than listed per case, because both rules already exist:
    /// ⌘C is offered exactly where there is a rewrite to copy, and Escape is
    /// worth showing exactly where the panel will not close itself. A state
    /// that vanishes in a second does not need to explain how to close it.
    var keyHints: [KeyHint] {
        var hints: [KeyHint] = []
        if copyableText != nil {
            hints.append(KeyHint(keys: "⌘C", action: "Copy", performs: .copy))
        }
        if autoDismissAfter == nil {
            hints.append(KeyHint(keys: "esc", action: "Cancel", performs: .cancel))
        }
        return hints
    }

    /// The panel state that describes an engine event.
    ///
    /// Written once here rather than in the coordinator, so there is only one
    /// copy of the mapping to keep right.
    init(_ event: RewriteEvent) {
        switch event {
        case let .preparing(progress):
            self = .preparing(progress: progress)
        case let .outputSnapshot(text):
            self = .generating(text: text)
        case .finished:
            // Not a result state. Generation finishing hands the transaction
            // back to the coordinator, which still has to validate the output
            // and write it into the source app — the slowest visible step on a
            // large selection. Showing the finished text with no activity
            // would make a working replacement look like a hang.
            self = .applying
        }
    }

    /// Exhaustive on purpose. No `default`: adding a case must be a compile
    /// error here, so nobody can ship a state that shows an icon and nothing
    /// else, or a colour and nothing else.
    var symbolName: String {
        switch self {
        case .capturing:          "text.cursor"
        case .preparing:          "arrow.down.circle"
        case .generating:         "sparkles"
        case .applying:           "square.and.pencil"
        case .success:            "checkmark.circle"
        case .readOnly:           "doc.on.clipboard"
        case .targetChanged:      "exclamationmark.triangle"
        case .refused:            "hand.raised"
        case .error:              "xmark.octagon"
        case .stylePicker:        "list.number"
        case .heldForManualCopy:  "tray.and.arrow.down"
        }
    }

    /// The words. Same rule as `symbolName`: exhaustive, no `default`.
    var title: String {
        switch self {
        case .capturing:          "Reading selection"
        case .preparing:          "Preparing model"
        case .generating:         "Rewriting"
        case .applying:           "Replacing selection"
        case .success:            "Replaced"
        // Both lead with the keystroke, because the outcome is not what the
        // user has to act on. Only sayable because ⌘V reaches the app
        // underneath again; do not write this sentence back if the panel ever
        // takes key status.
        case .readOnly:           "Press ⌘V to paste your rewrite"
        case .targetChanged:      "Press ⌘V to paste your rewrite"
        case .refused:            "The model declined"
        case .error:              "Rewrite failed"
        case .stylePicker:        "Choose a style"
        // ⌘C and not ⌘V, and the difference is the whole point: nothing has
        // been copied. The user's clipboard is untouched and this panel is
        // the only place the rewrite exists, so pointing at the clipboard
        // would point at nothing of theirs. Both steps are named because
        // neither happens on its own, and nothing here closes on a timer.
        case .heldForManualCopy:  "Press ⌘C, then paste your rewrite"
        }
    }

    /// How long this state stays on screen before the panel closes itself, or
    /// `nil` for a state that must be dismissed deliberately.
    ///
    /// `heldForManualCopy` is `nil` and must stay `nil`. It is the state the
    /// panel enters when the rewrite could neither be written back nor put on
    /// the pasteboard, which makes the panel the only copy of it. Closing that
    /// on a timer throws the user's rewrite away.
    var autoDismissAfter: Duration? {
        switch self {
        case .capturing, .preparing, .generating, .applying: nil
        case .stylePicker:                                   nil
        case .heldForManualCopy:                             nil
        // Long enough to see the tick, short enough not to sit on the thing
        // it is confirming. The tick is *wanted* — it acknowledges that the
        // replacement happened rather than merely reporting what the
        // document already shows — but at `.zero` it renders for a frame and
        // nobody sees it, and at the old 1200 ms it covered the text the user
        // had just asked to look at.
        //
        // 1000 and not 500, which was tried and which Pratik could not see.
        // The reason is measured rather than a theory about perception: the
        // panel collapses from a streaming height to a one-line tick, and
        // `present` resizes with `setFrame(animate:)`, which **blocks for
        // 293 ms** on that change. At 500 ms only 207 ms of the tick was
        // static — the rest was the panel shrinking, which in peripheral
        // vision reads as going away rather than as confirming. At 1000 ms
        // it is 707 ms static, 3.4× the still part rather than 2×.
        //
        // So the cheaper alternative, if this ever needs to come back down,
        // is not a shorter delay but presenting `.success` without the
        // animated resize: 500 ms fully static beats 1000 ms mostly moving.
        // That is a behaviour change and needs its own test.
        //
        // Presented rather than skipped for a separate reason: a screen
        // reader user gets no confirmation from the document changing, so
        // this is the only announcement the replaced path makes.
        case .success:                                       .seconds(1)
        case .readOnly, .targetChanged:                      .seconds(6)
        case .refused, .error:                               .seconds(8)
        }
    }

    /// The second line, where there is one. Never the streaming rewrite: that
    /// is the panel's body, not a caption for it.
    var detail: String? {
        switch self {
        case .capturing, .generating, .applying, .success, .stylePicker: nil
        case let .preparing(progress):
            progress.map { "\(Int($0 * 100))% downloaded" } ?? "Loading the model"
        // The two reasons are different situations and must not read alike:
        // one app cannot be typed into at all, so the paste has to go
        // somewhere else; the other can, and the text simply moved first.
        // "The text" said neither whose nor which, so both name the rewrite.
        case .readOnly:                      "Everest can't type into this app, so your rewrite is on the clipboard."
        case .targetChanged:                 "The text moved before Everest could replace it, so your rewrite is on the clipboard."
        case let .refused(reason):           reason
        case let .error(reason):             reason
        case let .heldForManualCopy(_, why): why
        }
    }

    /// What VoiceOver reads for the panel as a whole.
    ///
    /// Composed from the words and the reason, and deliberately never from the
    /// streaming text.
    var accessibilityValue: String {
        guard let detail else { return title }
        return "\(title). \(detail)"
    }

    /// Whether the panel may take key status while showing this state.
    ///
    /// Non-activating is the default because activating makes the source app
    /// resign and its selection stop being live. That is only worth protecting
    /// while a write is still intended. Terminal states will never write, so
    /// they can take focus — and taking focus is what lets ⌘C be consumed
    /// rather than also reaching the frontmost app, whose own copy would land
    /// after ours and overwrite the rewrite we just put on the clipboard.
    var acceptsKeyWindow: Bool {
        switch self {
        // Never, in any state. A key window receives *every* keystroke, and
        // this panel has no responder to answer them, so ⌘V died in an empty
        // chain — the state whose own words are "paste it where you want it"
        // was the one preventing the paste. Terminal states took key status
        // only to consume ⌘C, and `CGEventTapKeyInterceptor` now does that
        // while taking nothing else.
        case .capturing, .preparing, .generating, .applying, .stylePicker,
             .success, .readOnly, .targetChanged, .heldForManualCopy,
             .refused, .error:                                             false
        }
    }

    /// Whether this state has a keystroke it must take from the frontmost app.
    ///
    /// The picker, whose digits and arrows would otherwise land in the very
    /// document about to be rewritten; and any state holding a finished
    /// rewrite, where ⌘C must not also reach the source app, because that
    /// app's own Copy lands *after* ours and overwrites the rewrite on the
    /// clipboard. `refused` and `error` hold nothing, so there is nothing for
    /// a tap to take and none is armed.
    var needsKeyInterception: Bool {
        if case .stylePicker = self { return true }
        return copyableText != nil
    }

    /// The rewrite to show in the panel body, finished or still arriving.
    var bodyText: String? {
        switch self {
        case let .generating(text):            text
        case let .readOnly(text):              text
        case let .targetChanged(text):         text
        case let .heldForManualCopy(text, _):  text
        case .capturing, .preparing, .applying, .success,
             .refused, .error, .stylePicker:   nil
        }
    }

    /// The finished rewrite this state is holding, if it is holding one.
    ///
    /// `generating` is excluded on purpose: copying mid-stream would put half a
    /// paragraph on the pasteboard in place of whatever the user had there.
    var copyableText: String? {
        switch self {
        case let .readOnly(text):              text
        case let .targetChanged(text):         text
        case let .heldForManualCopy(text, _):  text
        case .capturing, .preparing, .generating, .applying, .success,
             .refused, .error, .stylePicker:   nil
        }
    }

    var kind: PanelStateKind {
        switch self {
        case .capturing:          .capturing
        case .preparing:          .preparing
        case .generating:         .generating
        case .applying:           .applying
        case .success:            .success
        case .readOnly:           .readOnly
        case .targetChanged:      .targetChanged
        case .refused:            .refused
        case .error:              .error
        case .stylePicker:        .stylePicker
        case .heldForManualCopy:  .heldForManualCopy
        }
    }
}
