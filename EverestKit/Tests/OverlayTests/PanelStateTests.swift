import Testing
import RewriteCore
@testable import Overlay

@Suite("PanelState")
struct PanelStateTests {
    /// One sample of every kind of panel the product can show.
    ///
    /// `PanelState.kind` is an exhaustive switch, so a twelfth case cannot be
    /// added without also adding a `PanelStateKind`, which makes this array
    /// incomplete and fails the test below until a sample is supplied.
    static let samples: [PanelState] = [
        .capturing,
        .preparing(progress: nil),
        .generating(text: "The quick brown fox"),
        .applying,
        .success,
        .readOnly(text: "The quick brown fox"),
        .targetChanged(text: "The quick brown fox"),
        .refused(reason: "the model declined this text"),
        .error(reason: "the model ran out of memory"),
        .stylePicker(presets: []),
        .heldForManualCopy(text: "The quick brown fox", reason: "the window moved"),
    ]

    @Test("covers exactly eleven kinds, one sample each")
    func coversElevenKinds() {
        #expect(PanelStateKind.allCases.count == 11)
        #expect(Set(Self.samples.map(\.kind)) == Set(PanelStateKind.allCases))
    }

    /// Colour is decoration. A green check and a red cross at 14pt are the same
    /// grey glyph to a user with deuteranopia, so every state has to say what it
    /// is in a symbol and in words.
    @Test("every state supplies both an SF Symbol and words, never colour alone")
    func everyStateHasSymbolAndWords() {
        for state in Self.samples {
            #expect(!state.symbolName.isEmpty, "\(state.kind) has no SF Symbol")
            #expect(!state.title.isEmpty, "\(state.kind) has no words")
        }
    }

    /// `heldForManualCopy` is the path where the rewrite could not be written
    /// back and is not on the pasteboard either, so the panel is holding the
    /// user's only copy of it. A timer that closes that panel deletes their
    /// work.
    ///
    /// `success` is the opposite, and is pinned by two relations rather than
    /// by its number, because the number is a taste call that has already
    /// moved twice.
    ///
    /// **Above zero**: the tick is wanted. It acknowledges the replacement,
    /// and at zero it renders for a frame and nobody sees it. **Below every
    /// other dismissing state**: it is the only one whose message the user
    /// can already read off their own document, so it is the only one that
    /// should get out of the way rather than be read. It sat at 1200 ms,
    /// which was long enough to be in the way of the thing it was confirming.
    ///
    /// The others must each stay longer: every one is carrying a reason, a
    /// refusal or a clipboard hand-off that has to be readable, and shrinking
    /// one of those towards `success` is the failure this guards.
    @Test("heldForManualCopy never auto-dismisses; success is visible but the briefest of those that do")
    func autoDismissIsPerState() {
        let expectedToDismiss: Set<PanelStateKind> = [
            .success, .readOnly, .targetChanged, .refused, .error,
        ]
        guard let success = PanelState.success.autoDismissAfter else {
            Issue.record("success must dismiss itself")
            return
        }

        #expect(success > .zero)

        for state in Self.samples {
            let dismisses = state.autoDismissAfter != nil
            #expect(dismisses == expectedToDismiss.contains(state.kind), "\(state.kind)")

            guard let delay = state.autoDismissAfter, state.kind != .success else { continue }
            #expect(delay > success, "\(state.kind)")
        }

        #expect(PanelState.heldForManualCopy(text: "rewritten", reason: "gone").autoDismissAfter == nil)
    }

    /// A Copy control only makes sense where the panel is holding a finished
    /// rewrite. Offering it mid-stream would put half a paragraph on the
    /// pasteboard over whatever the user had there.
    @Test("only the states holding a finished rewrite offer text to copy")
    func copyableTextIsPerState() {
        let holdingARewrite: Set<PanelStateKind> = [.readOnly, .targetChanged, .heldForManualCopy]

        for state in Self.samples {
            let offersCopy = state.copyableText != nil
            #expect(offersCopy == holdingARewrite.contains(state.kind), "\(state.kind)")
        }

        #expect(PanelState.heldForManualCopy(text: "rewritten", reason: "gone").copyableText == "rewritten")
    }

    /// Which states put the rewrite itself in the panel body. Keeping this a
    /// value rather than a rule the view invents is what stops the streaming
    /// text and the finished text being shown by two different code paths.
    @Test("the rewrite is shown while streaming and in every state that is holding one")
    func bodyTextIsPerState() {
        let showsTheRewrite: Set<PanelStateKind> = [
            .generating, .readOnly, .targetChanged, .heldForManualCopy,
        ]

        for state in Self.samples {
            #expect((state.bodyText != nil) == showsTheRewrite.contains(state.kind), "\(state.kind)")
        }

        #expect(PanelState.generating(text: "half a par").bodyText == "half a par")
    }

    /// The two copy-only outcomes have to say what to do, and say it first.
    ///
    /// They read "Copied — the text was not editable" over a grey line, which
    /// fuses an outcome with a diagnosis so it lands as an error; "the text"
    /// does not say whose, the user's or the rewrite's; and the one thing the
    /// user must actually *do* was the caption. They also explained
    /// themselves with the identical sentence, so a reader could not tell
    /// which of two different situations had happened — an app that cannot be
    /// typed into, or text that moved before it could be replaced.
    ///
    /// This is only sayable now that ⌘V works while the panel is up. It did
    /// not, until the panel stopped taking key status.
    @Test("the copy-only outcomes lead with the keystroke and explain themselves differently")
    func copyOnlyOutcomesLeadWithTheAction() {
        let readOnly = PanelState.readOnly(text: "the rewrite")
        let moved = PanelState.targetChanged(text: "the rewrite")

        // The action is the headline, not the caption.
        #expect(readOnly.title.contains("⌘V"))
        #expect(moved.title.contains("⌘V"))

        // And the reason tells them apart.
        #expect(readOnly.detail != moved.detail)
    }

    /// Which states take a keystroke away from the frontmost app.
    ///
    /// Only a `CGEventTap` can consume here, and while one is armed it is the
    /// first thing in the session to see every key the user types anywhere —
    /// so it exists only where the panel has a key it genuinely must have.
    /// The picker, whose digits and arrows would otherwise land in the very
    /// document about to be rewritten; and any state holding a finished
    /// rewrite, where the source app's own ⌘C would land after ours and
    /// overwrite it. `refused` and `error` hold nothing, so there is no ⌘C
    /// to take and no tap is armed for them.
    ///
    /// The panel itself is never key, in any state — see
    /// `PanelKeyWindowTests`. Making terminal panels key was the previous way
    /// to consume ⌘C, and a key window takes *every* keystroke, which is how
    /// it came to swallow the ⌘V the panel was telling the user to press.
    @Test("only the picker and a state holding a rewrite take keys from the app underneath")
    func onlyPickerAndRewriteStatesInterceptKeys() {
        let intercepting: Set<PanelStateKind> = [
            .stylePicker, .readOnly, .targetChanged, .heldForManualCopy,
        ]

        for state in Self.samples {
            #expect(state.needsKeyInterception == intercepting.contains(state.kind), "\(state.kind)")
        }
    }

    /// An invisible keyboard shortcut is the same as no shortcut. This panel
    /// is on screen for two seconds with no menu bar, no tooltip and no
    /// onboarding moment, so nobody will press ⌘C unless the panel says so.
    /// Making the hints a value rather than a styling choice is what stops a
    /// twelfth state shipping a copy action with no way to discover it.
    @Test("every state that can be acted on shows the keystroke that does it")
    func keyHintsArePerState() {
        let offersCopy: Set<PanelStateKind> = [.readOnly, .targetChanged, .heldForManualCopy]
        // States that will not go away on their own have to say how to close
        // them. The ones that vanish in a second or two do not.
        let offersCancel: Set<PanelStateKind> = [
            .capturing, .preparing, .generating, .applying, .stylePicker, .heldForManualCopy,
        ]

        for state in Self.samples {
            let keys = state.keyHints.map(\.keys)
            #expect(keys.contains("⌘C") == offersCopy.contains(state.kind), "\(state.kind)")
            #expect(keys.contains("esc") == offersCancel.contains(state.kind), "\(state.kind)")

            for hint in state.keyHints {
                #expect(!hint.action.isEmpty, "\(state.kind)")
            }
        }
    }

    /// The hint row is the button, not a caption beside one. That only works
    /// if each hint knows what it does, and matching on the displayed words
    /// would break the first time someone rewords a label.
    @Test("each hint carries the action it performs")
    func keyHintsCarryTheirAction() {
        let held = PanelState.heldForManualCopy(text: "the rewrite", reason: "the window moved")

        #expect(held.keyHints.map(\.performs) == [.copy, .cancel])
        #expect(PanelState.generating(text: "half a par").keyHints.map(\.performs) == [.cancel])
        #expect(PanelState.success.keyHints.isEmpty)
    }

    /// VoiceOver restarts its utterance every time an element's value changes.
    /// Putting the streaming rewrite in the panel's value makes it read the
    /// first few words over and over at token rate, which is unusable. The
    /// text is reachable as text; the value says what is happening.
    @Test("the panel's spoken value says what is happening and never carries the streaming text")
    func accessibilityValueOmitsStreamingText() {
        for state in Self.samples {
            #expect(!state.accessibilityValue.isEmpty, "\(state.kind)")
        }

        let streaming = PanelState.generating(text: "The quick brown fox jumps over the lazy dog")
        #expect(streaming.accessibilityValue.contains("quick brown fox") == false)

        // A reason nobody can hear is not a reason.
        let failed = PanelState.error(reason: "the model ran out of memory")
        #expect(failed.accessibilityValue.contains("ran out of memory"))
    }
}
