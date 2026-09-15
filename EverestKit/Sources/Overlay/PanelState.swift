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
        case .readOnly:           "Copied — the text was not editable"
        case .targetChanged:      "Copied — the original text had moved"
        case .refused:            "The model declined"
        case .error:              "Rewrite failed"
        case .stylePicker:        "Choose a style"
        case .heldForManualCopy:  "Copy this before closing"
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
        case .success:                                       .milliseconds(1200)
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
        case .readOnly:                      "It is on the clipboard — paste it where you want it."
        case .targetChanged:                 "It is on the clipboard — paste it where you want it."
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
        // A write is still intended. `stylePicker` included: activating here
        // costs the source app frontmost, and revalidation then downgrades the
        // whole transaction to `copiedOnly`.
        case .capturing, .preparing, .generating, .applying, .stylePicker: false
        // Auto-dismisses and asks nothing of the user.
        case .success:                                                     false
        case .readOnly, .targetChanged, .heldForManualCopy,
             .refused, .error:                                             true
        }
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
