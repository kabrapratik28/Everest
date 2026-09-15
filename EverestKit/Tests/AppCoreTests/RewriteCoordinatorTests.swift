import Engines
import Foundation
import Overlay
import RewriteCore
import Synchronization
import Testing
import TextBridge

@testable import AppCore

/// Reading the selection has to happen before anything is put on screen, and
/// for the style picker that ordering is the only defence there is.
///
/// A global key monitor observes keystrokes; it cannot consume them. So a `3`
/// pressed to choose style 3 also types a `3` into whatever app is frontmost —
/// which is the app whose text is about to be rewritten. Capturing first means
/// the stray digit lands after the bytes we already hold. Nothing in `Overlay`
/// can prevent this; it is the coordinator's job and only the coordinator's.
@Test("the selection is captured before the style picker is shown")
@MainActor
func capturesBeforeShowingTheStylePicker() async {
    let log = CallLog()
    let (panel, _) = makePanel(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        capture: { _ in
            log.record("capture")
            return .stub()
        },
        apply: ApplyRecorder(log: log)
    )

    await coordinator.chooseStyle()

    #expect(log.entries == ["capture", "present(stylePicker)"])
}

/// A capture that was refused has to stop the transaction dead. Falling through
/// to the picker would offer the user a choice that cannot be honoured, and —
/// worse for the secure-field case — would leave a picker armed over a password
/// field, where the digit they press to choose a style is typed into it.
@Test("a refused capture states why and never offers a style")
@MainActor
func aRefusedCaptureNeverShowsThePicker() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        capture: { _ in throw CaptureError.secureField },
        apply: ApplyRecorder(log: log)
    )

    await coordinator.chooseStyle()

    #expect(surface.presented.map(\.kind) == [.error])
    #expect(surface.presented.first?.detail == CaptureFailure.message(for: CaptureError.secureField))
}

/// `RewriteEvent.finished` is the *engine* finishing, not the transaction.
/// Validation and replacement still follow and can still fail, which is why
/// `Overlay` maps `.finished` to `.applying` and leaves the terminal state to
/// the coordinator. A coordinator that treated `.finished` as success would
/// show "Replaced" over text it never wrote.
///
/// The scripted output carries a preamble on purpose: what reaches the user's
/// document has to be `OutputValidator`'s cleaned string, not the raw one.
@Test("finished is not the end: the cleaned output is applied, and only then reported")
@MainActor
func finishedIsFollowedByValidationAndReplacement() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)
    let engine = StubEngine(events: [
        .outputSnapshot("Sure! Here's an im"),
        .finished("Sure! Here's an improved version:\n\nTightened text."),
    ])

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: engine,
        apply: recorder
    )

    await coordinator.quickImprove()

    #expect(recorder.applied == ["Tightened text."])
    // The write happens before success is claimed, never instead of it.
    #expect(
        log.entries.filter { $0 == "apply" || $0 == "present(success)" }
            == ["apply", "present(success)"]
    )
}

/// A stream that throws has to end the transaction where the user can see it.
/// Swallowing the error leaves the panel on "Rewriting" with no tokens
/// arriving and no way to tell a dead generation from a slow one.
@Test("an engine failure is shown, and nothing is written")
@MainActor
func anEngineFailureEndsTheTransactionVisibly() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: StubEngine(failure: UnexpectedFailure.somethingElse),
        apply: recorder
    )

    await coordinator.quickImprove()

    #expect(surface.presented.last?.kind == .error)
    #expect(recorder.applied.isEmpty)
}

/// `OutputValidator` is the second layer behind the prompt's safety frame, and
/// it is only a layer if something acts on it. Output it rejects must not
/// reach `ReplacementService`: a runaway generation written into the user's
/// document is unrecoverable, and there is no undo on our side of it.
@Test("output the validator rejects is refused, and never written")
@MainActor
func rejectedOutputIsNeverWritten() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        snapshot: .stub(text: "short"),
        // Far past the length ratio a genuine rewrite ever reaches.
        engine: StubEngine(events: [.finished(String(repeating: "runaway ", count: 200))]),
        apply: recorder
    )

    await coordinator.quickImprove()

    #expect(recorder.applied.isEmpty)
    #expect(surface.presented.last?.kind == .refused)

    // Two rejections with two different causes. "Nothing came back" and "far
    // more came back than went in" send the user to different places: one is
    // retry, the other is select less text.
    #expect(ValidationFailure.empty.message != ValidationFailure.lengthRatio(9).message)
}

/// `PanelState.autoDismissAfter` is decided and tested in `Overlay`, and until
/// something reads it the panel never closes on its own. The coordinator is
/// that reader, and it reads the interval off the state rather than keeping a
/// table of its own — so a state added later is dismissed on its own schedule
/// with no second place to update.
@Test("a finished rewrite closes its panel after the interval the state declares")
@MainActor
func aTerminalStateClosesItselfOnItsOwnSchedule() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let sleeper = RecordingSleeper(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: StubEngine(events: [.finished("Tightened text.")]),
        apply: ApplyRecorder(log: log),
        sleeper: sleeper
    )

    await coordinator.quickImprove()

    #expect(sleeper.requested.first == PanelState.success.autoDismissAfter)
    // The wait happens between showing the result and hiding it, not after.
    #expect(log.entries.suffix(3) == ["present(success)", "wait", "hide"])
    #expect(surface.hides == 1)
}

/// The one state that must never close itself.
///
/// `heldForManualCopy` is reached when the rewrite could be neither written
/// back nor put on the pasteboard, which makes the panel the only copy of it
/// in existence. A timer there deletes the user's work. `Overlay` encodes that
/// as `autoDismissAfter == nil`; this is the half that has to honour it.
@Test("a rewrite the panel is the only copy of is never closed on a timer")
@MainActor
func heldForManualCopyNeverAutoDismisses() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let sleeper = RecordingSleeper(log: log)
    let recorder = ApplyRecorder(
        log: log,
        outcome: .heldForManualCopy(cause: .clipboardTooLarge, reason: "your clipboard is too large to put back")
    )

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: StubEngine(events: [.finished("Tightened text.")]),
        apply: recorder,
        sleeper: sleeper
    )

    await coordinator.quickImprove()

    #expect(sleeper.requested.isEmpty)
    #expect(surface.hides == 0)
    // Still on screen, still holding the text the user has no other copy of.
    #expect(surface.presented.last?.bodyText == "Tightened text.")
}

/// One transaction at a time, and the newest one wins.
///
/// Two things have to happen, and they are not the same thing: the superseded
/// engine has to be told to stop, *and* whatever it emits on its way out has to
/// be ignored. Only the first is enough to leave a buffered `.finished` from
/// the abandoned generation writing itself into the user's document several
/// seconds after they asked for something else — which is a wrong-target write,
/// and those have no undo on either side.
@Test("a second hotkey press cancels the first generation and discards its output")
@MainActor
func asecondPressSupersedesTheFirst() async {
    let log = CallLog()
    let (panel, _) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)

    // Held open between the snapshot and the finish, so the second press lands
    // while the first is genuinely mid-generation.
    let abandoned = StubEngine(
        events: [.outputSnapshot("half a re"), .finished("ABANDONED OUTPUT")],
        gated: true
    )
    let replacement = StubEngine(events: [.finished("Second output.")])
    let queue = EngineQueue([abandoned, replacement])

    let coordinator = RewriteCoordinator(
        panel: panel,
        settings: makeSettings(),
        capture: { _ in .stub() },
        engineFor: { _ in queue.next() },
        apply: { text, target in recorder.apply(text, to: target) },
        sleeper: RecordingSleeper()
    )

    async let first: Void = coordinator.quickImprove()
    await abandoned.waitUntilStreaming()
    await coordinator.quickImprove()
    await first

    #expect(abandoned.cancels == 1)
    #expect(recorder.applied == ["Second output."])
}

/// The payoff of capturing first, and the reason it is not merely tidy.
///
/// A global monitor observes the picker's digit without consuming it, so the
/// `3` also types itself into the app being rewritten. If the coordinator read
/// the selection again after the pick, it would faithfully rewrite the
/// corrupted text and write the result back over the user's paragraph. The
/// selection is read once, before the picker, and that one reading is what
/// gets rewritten.
@Test("the style picker rewrites the selection read before it appeared")
@MainActor
func pickingAStyleUsesTheSelectionCapturedBeforeThePicker() async {
    let log = CallLog()
    let (panel, _) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)
    let engine = StubEngine(events: [.finished("Rewritten.")])
    let source = CaptureSource(["before the picker", "before the picker3"])

    let coordinator = RewriteCoordinator(
        panel: panel,
        settings: makeSettings(),
        capture: { source.next(excluding: $0) },
        engineFor: { _ in engine },
        apply: { text, target in recorder.apply(text, to: target) },
        sleeper: RecordingSleeper()
    )

    await coordinator.chooseStyle()
    await coordinator.pickStyle(Preset.builtInStyles[2])

    #expect(source.count == 1)
    #expect(engine.requests.map(\.text) == ["before the picker"])
    #expect(engine.requests.map(\.preset) == [Preset.builtInStyles[2]])
}

/// Escape, from the panel's `onCancel`.
///
/// Stopping the engine and taking the panel away are both required and neither
/// implies the other: a panel left up over a stopped engine sits on "Rewriting"
/// forever, and an engine left running behind a closed panel keeps a 4B model
/// decoding into nothing and can still reach the replacement step.
@Test("cancelling stops the generation and takes the panel away")
@MainActor
func cancellingStopsTheGenerationAndDismissesThePanel() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)
    let engine = StubEngine(events: [.outputSnapshot("half a re"), .finished("Too late.")], gated: true)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: engine,
        apply: recorder
    )

    async let running: Void = coordinator.quickImprove()
    await engine.waitUntilStreaming()
    await coordinator.cancel()
    await running

    #expect(engine.cancels == 1)
    #expect(surface.hides == 1)
    #expect(recorder.applied.isEmpty)
}

/// The excluded-app list is the only mitigation for the residual secure-field
/// gap in apps that expose no accessibility tree at all, so it has to be the
/// list the user can actually see in Settings — including the entry they added
/// thirty seconds ago because Everest had just read from their bank.
///
/// `SelectionCoordinator.excludedBundleIDs` is a `var` for exactly this, and
/// the shell is what keeps it current. Passing the list into every capture,
/// rather than assigning it once at launch, means there is no window in which
/// a freshly added exclusion is not yet in force and no second copy to go
/// stale.
@Test("the excluded-app list in force is the one currently in Settings")
@MainActor
func exclusionsAreReadFreshAtEveryCapture() async {
    let log = CallLog()
    let (panel, _) = makePanel(log: log)
    let settings = makeSettings()
    settings.excludedBundleIDs = ["com.example.bank"]
    let source = CaptureSource()

    let coordinator = makeCoordinator(
        panel: panel,
        settings: settings,
        capture: { source.next(excluding: $0) },
        engine: StubEngine(events: [.finished("Tightened.")]),
        apply: ApplyRecorder(log: log)
    )

    await coordinator.quickImprove()
    settings.excludedBundleIDs = ["com.example.bank", "com.example.vault"]
    await coordinator.quickImprove()

    #expect(
        source.exclusions == [
            ["com.example.bank"],
            ["com.example.bank", "com.example.vault"],
        ]
    )
}

/// The first hotkey press on a fresh install downloads 2.3 GB, and the panel
/// is the only place that can say so. Without progress reaching it the user
/// sees "Preparing model" and an unmoving spinner for several minutes and
/// concludes the app is broken.
///
/// The values have to arrive in order, which is why the coordinator funnels
/// the callback through an `AsyncStream` rather than spawning a task per
/// update: `Task { @MainActor in … }` per callback does not preserve creation
/// order, and a progress bar that jumps backwards reads as a failing download.
@Test("preparing a model reports its progress, in order, before any text arrives")
@MainActor
func preparationProgressReachesThePanelInOrder() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: StubEngine(
            events: [.finished("Tightened.")],
            progressSteps: [0.25, 0.5, 0.75, 1.0]
        ),
        apply: ApplyRecorder(log: log)
    )

    await coordinator.quickImprove()

    let reported = surface.presented.compactMap { state -> Double?? in
        if case let .preparing(progress) = state { return progress }
        return nil
    }
    #expect(reported == [nil, 0.25, 0.5, 0.75, 1.0])
}

/// A model that will not prepare — a truncated download, an architecture this
/// build cannot load — must end the transaction, not fall through to a stream
/// that has nothing behind it.
@Test("a model that fails to prepare ends the transaction")
@MainActor
func aFailedPreparationEndsTheTransaction() async {
    let log = CallLog()
    let (panel, surface) = makePanel(log: log)
    let recorder = ApplyRecorder(log: log)
    let engine = StubEngine(
        events: [.finished("never reached")],
        prepareFailure: UnexpectedFailure.somethingElse
    )

    let coordinator = makeCoordinator(
        panel: panel,
        settings: makeSettings(),
        engine: engine,
        apply: recorder
    )

    await coordinator.quickImprove()

    #expect(surface.presented.last?.kind == .error)
    #expect(engine.streamed == 0)
    #expect(recorder.applied.isEmpty)
}

/// Resolved per transaction, never cached at launch.
///
/// Two things change under a running app: the user switches model in Settings,
/// and Apple Intelligence is a System Settings toggle they can flip between
/// two hotkey presses. An engine chosen once at launch serves a model the user
/// has since moved away from, and there is nothing on screen to explain why.
@Test("the engine used is the one selected in Settings at that moment")
@MainActor
func theEngineIsResolvedFromSettingsEveryTime() async {
    let log = CallLog()
    let (panel, _) = makePanel(log: log)
    let settings = makeSettings()
    settings.engineID = .apple
    let asked = Mutex([EngineID]())

    let coordinator = RewriteCoordinator(
        panel: panel,
        settings: settings,
        capture: { _ in .stub() },
        engineFor: { id in
            asked.withLock { $0.append(id) }
            return StubEngine(id: id, events: [.finished("Tightened.")])
        },
        apply: { _, _ in .replaced },
        sleeper: RecordingSleeper()
    )

    await coordinator.quickImprove()
    settings.engineID = .qwen30B
    await coordinator.quickImprove()

    #expect(asked.withLock { $0 } == [.apple, .qwen30B])
}

/// A ready marker with no weights behind it is recoverable, and the words have
/// to say so.
///
/// `MLXEngine` has already cleared the marker by the time it throws, so the
/// very next attempt re-downloads instead of failing identically forever. The
/// generic "try again, or pick a different model" is wrong twice over here: it
/// suggests switching models, which fixes nothing, and it gives no hint that
/// the one useful action is to let the download run again.
@Test("a model whose weights went missing is reported as something to retry")
func aMissingSnapshotReadsAsRetryable() {
    let missing = EngineFailure.reason(for: ModelStoreError.readyMarkerWithoutWeights("mlx-community/x"))

    #expect(missing != EngineFailure.reason(for: UnexpectedFailure.somethingElse))
    #expect(missing.localizedCaseInsensitiveContains("download"))
}

/// Five refusals with five different remedies. Folding them into one "could not
/// read the selection" sends the user looking in the wrong place four times out
/// of five: granting a permission they already granted, hunting for a selection
/// they did make, shortening text that was never too long.
@Test("every capture refusal explains its own remedy")
func everyCaptureRefusalHasItsOwnMessage() {
    let messages = [
        CaptureFailure.message(for: CaptureError.accessibilityNotGranted),
        CaptureFailure.message(for: CaptureError.secureField),
        CaptureFailure.message(for: CaptureError.noSelection),
        // Sharing the `.noSelection` sentence would tell a user looking at
        // text they have selected to go and select some text, which is the
        // one remedy we know cannot help them.
        CaptureFailure.message(for: CaptureError.nothingCaptured),
        CaptureFailure.message(for: CaptureError.tooLong(12_000)),
        CaptureFailure.message(for: CaptureError.excludedApp("com.1password.1password")),
        // `capture()` is declared with untyped `throws`, so something other
        // than a `CaptureError` is unprovable rather than impossible. It still
        // has to produce words: a transaction that ends with an empty panel is
        // worse than one that ends with a vague sentence.
        CaptureFailure.message(for: UnexpectedFailure.somethingElse),
    ]

    #expect(Set(messages).count == messages.count)

    // The two cases that carry a payload have to spend it, or the payload is
    // theatre. `tooLong` is compared against another count rather than against
    // a literal, because the number is grouped for the user's locale and a
    // literal "12,000" would pass here and fail in Germany.
    #expect(
        CaptureFailure.message(for: CaptureError.tooLong(12_000))
            != CaptureFailure.message(for: CaptureError.tooLong(9_000))
    )
    // Addressed by case rather than by index, like `tooLong` above: an index
    // silently starts pointing at a different refusal the moment a case is
    // added to the list, and the assertion goes on passing or failing about
    // the wrong sentence.
    #expect(
        CaptureFailure.message(for: CaptureError.excludedApp("com.1password.1password"))
            .contains("com.1password.1password")
    )
}
