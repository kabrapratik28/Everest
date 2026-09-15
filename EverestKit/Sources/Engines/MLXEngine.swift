import Foundation
import RewriteCore

/// Runs a locally downloaded model.
public struct MLXEngine: RewriteEngine {
    public let id: EngineID
    let repoID: String
    let approxBytes: Int64
    let revision: String
    let store: ModelStore
    let fetcher: any ModelFetcher
    let producer: any TokenProducer
    private let transactions = TransactionBox()

    public init(
        id: EngineID,
        repoID: String,
        approxBytes: Int64,
        revision: String,
        store: ModelStore,
        fetcher: any ModelFetcher,
        producer: any TokenProducer
    ) {
        self.id = id
        self.repoID = repoID
        self.approxBytes = approxBytes
        self.revision = revision
        self.store = store
        self.fetcher = fetcher
        self.producer = producer
    }

    /// Builds an engine from its catalog entry.
    ///
    /// This is the initializer the app uses. `ModelCatalog` is the single
    /// place recording which weights were actually tested, so taking the repo
    /// and the pinned commit from the spec is what stops a call site quietly
    /// substituting a branch.
    public init(
        spec: ModelSpec,
        store: ModelStore,
        fetcher: any ModelFetcher,
        producer: any TokenProducer
    ) {
        self.init(
            id: spec.id,
            repoID: spec.repoID,
            approxBytes: spec.approxBytes,
            revision: spec.revision,
            store: store,
            fetcher: fetcher,
            producer: producer
        )
    }

    /// Downloads the weights if they are missing, then proves they load.
    ///
    /// `markReady` is reached only after `load` returns. A download can
    /// complete and still produce a model that will not run, and a model in
    /// that state marked ready would fail identically on every hotkey press
    /// with no path in the UI that would ever re-download it.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if store.isReady(repoID, revision: revision) {
            // The marker is a claim about weights, so check they are still
            // there. Trusting it blindly turns a deleted snapshot into a
            // failure at generation time, on every hotkey press, with an
            // error that names the wrong thing.
            guard let installed = store.installedSnapshot(for: repoID, revision: revision) else {
                // Withdraw the claim so the next prepare re-downloads rather
                // than failing this way forever.
                try store.clearReady(repoID)
                throw ModelStoreError.readyMarkerWithoutWeights(repoID)
            }
            try await producer.load(from: installed)
            return
        }

        let downloader = ModelDownloader(store: store, fetcher: fetcher)
        let directory = try await downloader.download(
            repoID: repoID,
            revision: revision,
            progress: progress
        )
        try await producer.load(from: directory)
        try store.markReady(repoID, revision: revision)
    }

    /// Whether this engine can serve a rewrite right now.
    ///
    /// Keyed on the readiness marker rather than on files being present,
    /// because a completed download and a loadable model are not the same
    /// thing. See `ModelStore.markReady`.
    public func availability() async -> EngineAvailability {
        store.isReady(repoID, revision: revision)
            ? .ready
            : .needsDownload(bytes: approxBytes)
    }

    /// Streams a rewrite as cumulative snapshots.
    ///
    /// MLX yields the text each token decoded to — `"Hel"`, `"lo"`,
    /// `" there"` — and this is the one place those are accumulated. It is
    /// done here rather than in the overlay or the coordinator because
    /// Apple's `streamResponse` is already cumulative: if both engines
    /// emitted deltas, `AppleFoundationEngine` would have to diff Apple's
    /// snapshots back into deltas so something downstream could re-accumulate
    /// them. A dropped or coalesced UI update also costs nothing with
    /// snapshots, where with deltas it silently corrupts the result.
    public func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = PromptBuilder.build(text: request.text, preset: request.preset)
                    let inputTokens = try await producer.inputTokenCount(for: prompt)
                    let settings = EngineLimits.settings(forInputTokens: inputTokens)

                    var accumulated = ""
                    var stop: GenerationStop?
                    for try await event in producer.stream(prompt: prompt, settings: settings) {
                        switch event {
                        case let .delta(text):
                            accumulated += text
                            continuation.yield(.outputSnapshot(accumulated))
                        case let .stopped(reason):
                            stop = reason
                        }
                    }
                    // Without this, a stream cancelled mid-decode still
                    // emits a `.finished` carrying a half-written rewrite,
                    // which the replacement path would happily apply.
                    try Task.checkCancellation()

                    // The budget ran out before the model reached the end of
                    // its sentence, so `accumulated` is the first part of a
                    // rewrite. Refused here rather than validated downstream:
                    // a truncated rewrite is ordinary prose that stops, and
                    // nothing reading only the text can tell.
                    //
                    // Only `.budgetExhausted` refuses. `.cancelled` is what
                    // mlx-swift-lm falls back to whenever it cannot say why
                    // the iterator ended, and a nil reason is a producer that
                    // does not report one, so neither is evidence of anything.
                    if stop == .budgetExhausted { throw GenerationError.truncated }

                    // Only when there is **no** exact answer to defer to.
                    //
                    // `stopReason` is a dependency's promise, and a version
                    // that stopped yielding completion info would restore the
                    // original data-loss bug invisibly, so the text check
                    // still has to exist. But running it over a reported
                    // `.endOfText` overrides the exact signal with a guess,
                    // and can only produce false refusals — a real truncation
                    // reports `.budgetExhausted` and was caught a line above.
                    // It cost valid rewrites ending in a colon or a list item
                    // whenever the source happened to end as a sentence,
                    // which is the guesswork reading `stopReason` was adopted
                    // to remove.
                    if stop == nil,
                        OutputCompleteness.looksTruncated(accumulated, source: request.text)
                    {
                        throw GenerationError.truncated
                    }

                    continuation.yield(.finished(accumulated))
                    continuation.finish()
                } catch is CancellationError {
                    // A cancelled rewrite is not a failure the user needs
                    // told about; they are the one who cancelled it.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Registered before `stream(_:)` returns, so `cancel()` on the
            // next line finds it. See `TransactionBox`.
            transactions.begin(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the in-flight rewrite. No further events are emitted.
    public func cancel() async {
        transactions.cancel()
    }
}
