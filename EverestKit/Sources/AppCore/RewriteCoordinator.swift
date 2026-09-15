import Foundation
import Overlay
import RewriteCore
import TextBridge

/// Drives one rewrite from hotkey to replaced text, and owns exactly one at a
/// time.
public actor RewriteCoordinator {
    private let panel: FloatingPanelController
    private let settings: AppSettings
    /// Reads the selection, given the exclusion list to honour.
    ///
    /// The list is a parameter rather than something the adapter closes over,
    /// so the one in force is always the one currently in Settings.
    /// `SelectionCoordinator.excludedBundleIDs` is a `var` for this reason:
    /// a list frozen at launch goes stale the moment the user adds their bank,
    /// and nothing tells them it has.
    private let capture: @MainActor @Sendable ([String]) throws -> TargetSnapshot
    private let engineFor: @Sendable (EngineID) -> any RewriteEngine
    private let apply: @MainActor @Sendable (String, TargetSnapshot) -> ReplaceOutcome
    private let sleeper: any Sleeping

    /// Bumped by every new transaction. A generation that finds the counter
    /// moved on has been superseded and must touch nothing: not the panel, not
    /// the user's document.
    private var generation = 0

    /// The engine serving the current generation, kept only so a new hotkey
    /// press can stop it.
    private var active: (any RewriteEngine)?

    /// The selection the style picker is waiting on. Held here rather than
    /// passed through the panel because `TargetSnapshot` is `@unchecked
    /// Sendable` — the actor is its only owner, and it is never handed to a
    /// second task.
    private var pending: TargetSnapshot?

    public init(
        panel: FloatingPanelController,
        settings: AppSettings,
        capture: @escaping @MainActor @Sendable ([String]) throws -> TargetSnapshot,
        engineFor: @escaping @Sendable (EngineID) -> any RewriteEngine,
        apply: @escaping @MainActor @Sendable (String, TargetSnapshot) -> ReplaceOutcome,
        sleeper: any Sleeping = TaskSleeper()
    ) {
        self.panel = panel
        self.settings = settings
        self.capture = capture
        self.engineFor = engineFor
        self.apply = apply
        self.sleeper = sleeper
    }

    // MARK: - Entry points

    /// `⌘I`.
    public func quickImprove() async {
        guard let snapshot = await begin() else { return }
        let preset = await MainActor.run { settings.quickImprove }
        await run(snapshot: snapshot, preset: preset)
    }

    /// `⌘⇧I`. Reads the selection, *then* offers the styles.
    ///
    /// The ordering is the whole guard, and it is the coordinator's alone.
    /// `Overlay`'s key monitor observes keystrokes without consuming them, so
    /// the `3` that picks style 3 is also typed into the frontmost app — the
    /// one holding the text about to be rewritten. Capturing first means the
    /// stray digit lands after the bytes are already in hand. A panel shown
    /// first can also move accessibility focus before it is read.
    public func chooseStyle() async {
        guard let snapshot = await begin() else { return }
        pending = snapshot
        await MainActor.run { panel.show(.stylePicker(presets: settings.styles)) }
    }

    /// The panel's `onCancel`: Escape, from an `NSEvent` monitor.
    ///
    /// Both halves are needed. Leaving the engine running behind a closed panel
    /// keeps a 4B model decoding into nothing and still reaches the replacement
    /// step; leaving the panel up over a stopped engine sits on "Rewriting"
    /// until the user force-quits.
    public func cancel() async {
        await supersede()
        await MainActor.run { panel.dismiss() }
    }

    /// The panel's `onPickStyle`, arriving with the selection already captured.
    public func pickStyle(_ preset: Preset) async {
        guard let snapshot = pending else { return }
        pending = nil
        await run(snapshot: snapshot, preset: preset)
    }

    // MARK: - The transaction

    /// Supersedes any predecessor, then reads the selection. `nil` means the
    /// transaction cannot start and the user has been told why.
    private func begin() async -> TargetSnapshot? {
        await supersede()
        do {
            return try await MainActor.run { try capture(settings.excludedBundleIDs) }
        } catch {
            // `.error`, not `.refused`. `PanelState.refused` reads "The model
            // declined", which is a false account of a refusal that happened
            // before any model was consulted. `.refused` is kept for output
            // the validator threw out.
            let state = PanelState.error(reason: CaptureFailure.message(for: error))
            await MainActor.run { panel.show(state) }
            await autoDismiss(state, generation: generation)
            return nil
        }
    }

    /// Ends the previous transaction before a new one reads anything.
    private func supersede() async {
        generation &+= 1
        pending = nil
        await active?.cancel()
        active = nil
    }

    private func run(snapshot: TargetSnapshot, preset: Preset) async {
        let mine = generation
        let engine = engineFor(await MainActor.run { settings.engineID })
        active = engine

        await MainActor.run { panel.show(.preparing(progress: nil)) }

        do {
            try await prepare(engine)
        } catch {
            guard mine == generation else { return }
            await settle(EngineFailure.state(for: error), generation: mine)
            return
        }
        guard mine == generation else { return }

        var finished: String?
        do {
            for try await event in engine.stream(RewriteRequest(text: snapshot.text, preset: preset)) {
                guard mine == generation else { return }
                if case let .finished(text) = event { finished = text }
                await MainActor.run { panel.update(from: event) }
            }
        } catch {
            guard mine == generation else { return }
            await settle(EngineFailure.state(for: error), generation: mine)
            return
        }

        guard mine == generation else { return }
        // No `.finished` means the stream was cancelled mid-decode. There is
        // nothing to validate and nothing to write.
        guard let finished else { return }

        switch OutputValidator.validate(finished, source: snapshot.text) {
        // `.refused` and not `.error`: the model really did decline, in the
        // sense that what came back was not a rewrite. Nothing was written.
        case let .failure(failure):
            await settle(.refused(reason: failure.message), generation: mine)
        case let .success(text):
            let outcome = await MainActor.run { apply(text, snapshot) }
            guard mine == generation else { return }
            await settle(PanelOutcome.state(for: outcome, text: text), generation: mine)
        }
    }

    /// Downloads and loads the weights if they are not already there, showing
    /// how far along it is.
    ///
    /// The progress callback is `@Sendable` and synchronous, so its values have
    /// to cross onto the main actor somehow. They go through an `AsyncStream`
    /// and are drained in order here, rather than each spawning its own
    /// `Task { @MainActor in … }`: tasks created in sequence are not guaranteed
    /// to *run* in sequence, and a percentage that goes backwards reads as a
    /// download that is failing. On a first run this is several minutes and
    /// 2.3 GB, so the difference is not cosmetic.
    private func prepare(_ engine: any RewriteEngine) async throws {
        let progress = AsyncStream<Double>.makeStream()
        let preparing = Task {
            defer { progress.continuation.finish() }
            try await engine.prepare { progress.continuation.yield($0) }
        }
        for await fraction in progress.stream {
            await MainActor.run { panel.update(.preparing(progress: fraction)) }
        }
        try await preparing.value
    }

    // MARK: - Ending a transaction

    /// Moves the panel to its final state and lets that state close itself.
    private func settle(_ state: PanelState, generation mine: Int) async {
        await MainActor.run { panel.update(state) }
        await autoDismiss(state, generation: mine)
    }

    /// Closes the panel after the interval the state itself declares.
    ///
    /// The interval is read off `PanelState` rather than kept in a table here,
    /// so a state added later arrives with its own schedule and there is no
    /// second place to forget. A `nil` interval means the state must be
    /// dismissed deliberately — `heldForManualCopy` is the only one, and it is
    /// `nil` because the panel is then holding the user's only copy of their
    /// rewrite and a timer would throw it away.
    private func autoDismiss(_ state: PanelState, generation mine: Int) async {
        guard let delay = state.autoDismissAfter else { return }
        try? await sleeper.sleep(for: delay)
        // A newer transaction already owns the panel; its result is not ours
        // to close.
        guard mine == generation else { return }
        await MainActor.run { panel.dismiss() }
    }
}
