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

    /// One transaction's identity, bound the moment it begins.
    ///
    /// The generation travels *with* the transaction instead of being read
    /// again later, and that is the whole point. `run` used to sample
    /// `generation` on entry — after `quickImprove` had already suspended on
    /// the settings read — so a second press landing in that window bumped
    /// the counter, the first resumed, and it adopted the *new* token. Two
    /// transactions then held one generation and every guard compared it to
    /// itself, so both reached the write. No picker and no cancel needed:
    /// two hotkey presses did it.
    struct Transaction {
        let snapshot: TargetSnapshot
        let generation: Int
    }

    /// The transaction the style picker is waiting on. Held here rather than
    /// passed through the panel because `TargetSnapshot` is `@unchecked
    /// Sendable` — the actor is its only owner, and it is never handed to a
    /// second task. It carries its own generation, so a snapshot that
    /// outlived its transaction refuses itself rather than being stamped with
    /// whatever token is current by the time it is picked.
    private(set) var pending: Transaction?

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

    /// The Quick Improve hotkey. Deliberately not written out here — the
    /// defaults moved once and every glyph in the codebase went stale with
    /// them; `HotkeyManager` owns what it is bound to.
    public func quickImprove() async {
        guard let transaction = await begin() else { return }
        // This read suspends, and a second press can land here. Harmless now
        // only because the token above is already bound.
        let preset = await MainActor.run { settings.quickImprove }
        await run(transaction, preset: preset)
    }

    /// The Choose Style hotkey. Reads the selection, *then* offers the styles.
    ///
    /// The ordering is the whole guard, and it is the coordinator's alone.
    /// `Overlay` now arms a consuming `CGEventTap` while the picker is up, so
    /// the `3` that picks style 3 no longer reaches the frontmost app — but
    /// that tap is keyed to the code signature and `tapCreate` returns nil
    /// without the grant, and then the digit lands in the very text about to
    /// be rewritten. Capturing first means it arrives after the bytes are in
    /// hand either way. A panel shown first can also move accessibility focus
    /// before it is read.
    public func chooseStyle() async {
        guard let transaction = await begin() else { return }
        pending = transaction
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
    /// The panel's `onPickStyle`, arriving with the selection already
    /// captured — and with the generation it was captured under, which is
    /// checked here. `supersede()` also clears `pending`, but that is memory
    /// hygiene (root §6: only the current transaction's original in memory),
    /// not what makes this safe. What makes it safe is that a snapshot which
    /// outlived its transaction carries a stale token and is refused.
    public func pickStyle(_ preset: Preset) async {
        guard let transaction = pending, transaction.generation == generation else { return }
        pending = nil
        await run(transaction, preset: preset)
    }

    // MARK: - The transaction

    /// Supersedes any predecessor, then reads the selection. `nil` means the
    /// transaction cannot start and the user has been told why.
    /// Internal, not private, so a test can bind a token and then supersede
    /// it without having to race two `quickImprove` calls into the one
    /// window where the bug used to appear.
    func begin() async -> Transaction? {
        await supersede()
        // Bound here, before the first suspension, and never re-read.
        let mine = generation
        do {
            let snapshot = try await MainActor.run { try capture(settings.excludedBundleIDs) }
            return Transaction(snapshot: snapshot, generation: mine)
        } catch {
            // `.error`, not `.refused`. `PanelState.refused` reads "The model
            // declined", which is a false account of a refusal that happened
            // before any model was consulted. `.refused` is kept for output
            // the validator threw out.
            let state = PanelState.error(reason: CaptureFailure.message(for: error))
            await MainActor.run { panel.show(state) }
            await autoDismiss(state, generation: mine)
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

    func run(_ transaction: Transaction, preset: Preset) async {
        let mine = transaction.generation
        let snapshot = transaction.snapshot
        // Refused before it touches anything. A stale transaction that got
        // this far would overwrite `active` — so the next supersede would
        // cancel the wrong engine — and repaint a panel it no longer owns.
        guard mine == generation else { return }
        let engine = engineFor(await MainActor.run { settings.engineID })
        active = engine

        await MainActor.run { panel.show(.preparing(progress: nil)) }

        do {
            try await prepare(engine, generation: mine)
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
        // No `.finished` means the stream ended without producing a rewrite.
        // Nothing to validate and nothing to write — but this transaction is
        // still the current one, established one line above, so returning
        // silently strands the panel on "Rewriting" with nothing coming and
        // no auto-dismiss. The observed route in is the Settings test box
        // cancelling a hotkey rewrite through the engine they share, and the
        // only way out for the user was force-quitting.
        guard let finished else {
            await settle(
                .error(reason: "The rewrite stopped before it produced anything. Try again."),
                generation: mine
            )
            return
        }

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
    /// Superseded mid-download, it stops the download and paints nothing.
    ///
    /// Both halves were missing and both were visible to the user. Without the
    /// generation check, a percentage arriving after Escape re-presents a
    /// panel that has already been torn down — and teardown has released the
    /// key monitors, so the panel that comes back cannot be closed with
    /// Escape again. Without the cancel, a 2.3 GB fetch the user abandoned
    /// four minutes in carries on to the end with nothing waiting for it.
    private func prepare(_ engine: any RewriteEngine, generation mine: Int) async throws {
        let progress = AsyncStream<Double>.makeStream()
        let preparing = Task {
            defer { progress.continuation.finish() }
            try await engine.prepare { progress.continuation.yield($0) }
        }
        for await fraction in progress.stream {
            guard mine == generation else {
                preparing.cancel()
                return
            }
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
