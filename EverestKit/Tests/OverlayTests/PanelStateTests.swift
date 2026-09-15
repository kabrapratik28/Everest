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
    /// work. `success` by contrast has already replaced the text and should get
    /// out of the way on its own.
    @Test("heldForManualCopy never auto-dismisses, success does")
    func autoDismissIsPerState() {
        let expectedToDismiss: Set<PanelStateKind> = [
            .success, .readOnly, .targetChanged, .refused, .error,
        ]

        for state in Self.samples {
            let dismisses = state.autoDismissAfter != nil
            #expect(dismisses == expectedToDismiss.contains(state.kind), "\(state.kind)")
        }

        #expect(PanelState.heldForManualCopy(text: "rewritten", reason: "gone").autoDismissAfter == nil)
        #expect(PanelState.success.autoDismissAfter != nil)
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

    /// The panel is non-activating to protect the user's selection: the moment
    /// this app activates, the source app resigns and its selection stops
    /// being live. That cost is only worth paying while a write is still
    /// intended. In a terminal state nothing will be written, so the panel can
    /// safely take key status — which is what lets ⌘C be *consumed* instead of
    /// also reaching the frontmost app, where that app's own copy would land
    /// after ours and overwrite the rewrite on the clipboard.
    ///
    /// The picker is deliberately not in the list. We still intend to replace,
    /// so activating would make the source app lose frontmost and revalidation
    /// would downgrade the whole transaction to `copiedOnly`.
    @Test("only a terminal state that needs the user may take key status")
    func onlyTerminalStatesAcceptKey() {
        let mayBecomeKey: Set<PanelStateKind> = [
            .readOnly, .targetChanged, .heldForManualCopy, .refused, .error,
        ]

        for state in Self.samples {
            #expect(state.acceptsKeyWindow == mayBecomeKey.contains(state.kind), "\(state.kind)")
        }

        // `success` auto-dismisses and asks nothing of the user, so there is
        // no reason to take focus for it.
        #expect(PanelState.success.acceptsKeyWindow == false)
        #expect(PanelState.stylePicker(presets: []).acceptsKeyWindow == false)
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
