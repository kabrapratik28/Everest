import Foundation
import RewriteCore
import Testing

@testable import Engines

@Suite("MLXEngine")
struct MLXEngineTests {
    static let repoID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    /// A commit hash, not a branch. See `ModelDownloader.download`.
    static let pinned = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

    static func request(_ text: String = "the quick brown fox") -> RewriteRequest {
        RewriteRequest(text: text, preset: .quickImprove)
    }

    static func engine(
        producer: ScriptedTokenProducer,
        root: URL,
        fetcher: ScriptedFetcher = ScriptedFetcher(rawProgress: [1.0])
    ) -> MLXEngine {
        MLXEngine(
            id: .qwen4B,
            repoID: repoID,
            approxBytes: 2_300_000_000,
            revision: Self.pinned,
            store: ModelStore(root: root),
            fetcher: fetcher,
            producer: producer
        )
    }

    /// The pinned commit comes from the catalog, not from a call site.
    ///
    /// `ModelCatalog` is the one place the app records which weights were
    /// tested. An engine constructed from loose arguments can be handed a
    /// branch name by any caller that forgets, and nothing downstream would
    /// notice — the `.ready` marker matches whatever string it was given.
    @Test("the engine takes its repo and pinned revision from the catalog spec")
    func engineTakesRepoAndPinnedRevisionFromSpec() async throws {
        let temp = try TempDirectory()
        let spec = try #require(ModelCatalog.all.first { $0.id == .qwen4B })
        let fetcher = ScriptedFetcher(rawProgress: [1.0])
        let engine = MLXEngine(
            spec: spec,
            store: ModelStore(root: temp.url),
            fetcher: fetcher,
            producer: ScriptedTokenProducer(deltas: [])
        )

        try await engine.prepare { _ in }

        #expect(engine.id == .qwen4B)
        #expect(fetcher.revisionRequested == spec.revision)
        #expect(fetcher.repoRequested == spec.repoID)
    }

    /// A download finishing and a model working are different claims.
    ///
    /// The weights can arrive complete by every check the downloader can make
    /// and still be a truncated safetensors file, or an architecture this
    /// build of mlx-swift-lm has no entry for. If `prepare` marked the model
    /// ready on bytes alone, that model would report `.ready` forever, fail
    /// identically on every hotkey press, and never re-download.
    ///
    /// Both halves are asserted because the failing half alone is vacuous:
    /// `isReady == false` also holds for a `prepare` that does nothing at all.
    @Test("prepare marks the model ready only once the weights have loaded")
    func prepareMarksReadyOnlyAfterAProvenLoad() async throws {
        let unloadable = try TempDirectory()
        let unloadableStore = ModelStore(root: unloadable.url)
        let failing = MLXEngine(
            id: .qwen4B,
            repoID: Self.repoID,
            approxBytes: 2_300_000_000,
            revision: Self.pinned,
            store: unloadableStore,
            fetcher: ScriptedFetcher(rawProgress: [1.0]),
            producer: ScriptedTokenProducer(deltas: [], loadFailure: .weightsUnloadable)
        )

        await #expect(throws: ProducerFailure.weightsUnloadable) {
            try await failing.prepare { _ in }
        }
        #expect(unloadableStore.isReady(Self.repoID, revision: Self.pinned) == false)

        let loadable = try TempDirectory()
        let loadableStore = ModelStore(root: loadable.url)
        let working = Self.engine(
            producer: ScriptedTokenProducer(deltas: []),
            root: loadable.url
        )

        try await working.prepare { _ in }
        #expect(loadableStore.isReady(Self.repoID, revision: Self.pinned))
    }

    /// MLX hands back the text each token decoded to — `"Hel"`, `"lo"`,
    /// `" there"` — while `RewriteEvent.outputSnapshot` carries the whole
    /// output so far. The accumulation happens here, once.
    ///
    /// It is not done in the overlay or the coordinator because Apple's
    /// `streamResponse` is already cumulative: if the engines both emitted
    /// deltas, `AppleFoundationEngine` would have to diff Apple's snapshots
    /// back into deltas so something downstream could re-accumulate them.
    /// Snapshots also survive a dropped or coalesced UI update, where a
    /// dropped delta corrupts the result permanently and silently.
    @Test("token deltas are emitted as cumulative snapshots")
    func tokenDeltasBecomeCumulativeSnapshots() async throws {
        let temp = try TempDirectory()
        let engine = Self.engine(
            producer: ScriptedTokenProducer(deltas: ["Hel", "lo", " there"]),
            root: temp.url
        )

        var snapshots: [String] = []
        for try await event in engine.stream(Self.request()) {
            if case .outputSnapshot(let text) = event { snapshots.append(text) }
        }

        #expect(snapshots == ["Hel", "Hello", "Hello there"])
    }

    /// The last event carries the whole rewrite, so a consumer that only cares
    /// about the result never has to accumulate anything itself. This is what
    /// the replacement path reads; it must not have to remember the last
    /// snapshot it happened to see.
    @Test("the finished event carries the complete final text")
    func finishedCarriesTheCompleteFinalText() async throws {
        let temp = try TempDirectory()
        let engine = Self.engine(
            producer: ScriptedTokenProducer(deltas: ["Hel", "lo", " there"]),
            root: temp.url
        )

        var finished: String?
        for try await event in engine.stream(Self.request()) {
            if case .finished(let text) = event { finished = text }
        }

        #expect(finished == "Hello there")
    }

    /// Settings needs to offer a download button with a size on it before the
    /// weights exist, and stop offering it afterwards.
    ///
    /// Readiness is deliberately not "are there files in the directory". A
    /// download can finish and still leave a truncated safetensors file that
    /// no version of this app can load, so `.ready` means a load was proven,
    /// not that bytes arrived.
    @Test("availability reports needsDownload without weights and ready with them")
    func availabilityReflectsWhetherTheModelIsProven() async throws {
        let temp = try TempDirectory()
        let store = ModelStore(root: temp.url)
        let engine = Self.engine(producer: ScriptedTokenProducer(deltas: []), root: temp.url)

        #expect(await engine.availability() == .needsDownload(bytes: 2_300_000_000))

        try store.markReady(Self.repoID, revision: Self.pinned)

        #expect(await engine.availability() == .ready)
    }

    /// A readiness marker is a claim about weights. Honour it only while the
    /// weights it vouches for are actually there.
    ///
    /// `prepare` short-circuits on the marker, so without this check a model
    /// whose snapshot has been deleted — by a disk cleaner, a half-finished
    /// manual tidy, a `.ready` file that outlived its blobs — reports ready,
    /// skips the download, and then fails at generation time on every hotkey
    /// press. Failing here instead means the error names the real problem,
    /// and clearing the marker means the next `prepare` re-downloads rather
    /// than failing the same way forever.
    ///
    /// The happy half is asserted too: without it, a `prepare` that threw
    /// unconditionally would pass.
    @Test("a readiness marker is honoured only while the weights it vouches for exist")
    func readinessMarkerIsHonouredOnlyWhileWeightsExist() async throws {
        let installed = try TempDirectory()
        let installedStore = ModelStore(root: installed.url)
        try installedStore.markReady(Self.repoID, revision: Self.pinned)
        try installed.writeFile(
            "\(ModelStore.cacheName(for: Self.repoID))/snapshots/\(Self.pinned)/config.json",
            bytes: 12
        )
        let producer = ScriptedTokenProducer(deltas: [])
        let fetcher = ScriptedFetcher(rawProgress: [1.0])
        let ready = Self.engine(producer: producer, root: installed.url, fetcher: fetcher)

        try await ready.prepare { _ in }

        #expect(producer.loadedFrom?.lastPathComponent == Self.pinned)
        #expect(fetcher.revisionRequested == nil)

        let orphaned = try TempDirectory()
        let orphanedStore = ModelStore(root: orphaned.url)
        try orphanedStore.markReady(Self.repoID, revision: Self.pinned)
        let stale = Self.engine(producer: ScriptedTokenProducer(deltas: []), root: orphaned.url)

        await #expect(throws: ModelStoreError.readyMarkerWithoutWeights(Self.repoID)) {
            try await stale.prepare { _ in }
        }
        #expect(orphanedStore.isReady(Self.repoID, revision: Self.pinned) == false)
    }

    /// `cancel()` has to stop the decoder, not just stop listening to it.
    ///
    /// Dropping the results instead would leave the GPU decoding several
    /// hundred tokens for a panel that is already gone, which on the 30B
    /// option is seconds of a stalled machine. `deltasYielded` is the
    /// assertion that tells the two apart: a cancel that only unsubscribes
    /// leaves the producer running to the end and the count at 5.
    ///
    /// The task must also be registered synchronously, before `stream(_:)`
    /// returns. An earlier implementation hopped to an actor to record it,
    /// which left a window where a caller doing `stream()` then `cancel()` on
    /// the next line found nothing registered and left the generation running.
    @Test("cancel stops consumption and emits nothing further")
    func cancelStopsConsumptionAndEmitsNothingFurther() async throws {
        let temp = try TempDirectory()
        let producer = ScriptedTokenProducer(
            deltas: ["one ", "two ", "three ", "four ", "five "],
            delayBetweenDeltas: .milliseconds(80)
        )
        let engine = Self.engine(producer: producer, root: temp.url)

        var iterator = engine.stream(Self.request()).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first != nil)

        await engine.cancel()

        var eventsAfterCancel = 0
        while try await iterator.next() != nil {
            eventsAfterCancel += 1
        }

        #expect(eventsAfterCancel == 0)
        #expect(producer.deltasYielded < producer.deltas.count)
    }

    /// The engine has to actually hand `EngineLimits` to the decoder, not just
    /// own the constants.
    ///
    /// This is driven in the same cycle as the snapshot test above rather than
    /// its own, because there is no *correct* minimal implementation of
    /// cumulative snapshots that gets the settings wrong — the engine cannot
    /// call the producer without passing something. Splitting it into a later
    /// cycle would have produced a test that passed the first time it ran,
    /// which proves nothing.
    @Test("the decoder is given temperature 0.2, an 8192 context cap, and the input's budget")
    func decoderReceivesTheConfiguredLimits() async throws {
        let temp = try TempDirectory()
        let producer = ScriptedTokenProducer(deltas: ["x"], promptTokens: 200)
        let engine = Self.engine(producer: producer, root: temp.url)

        for try await _ in engine.stream(Self.request()) {}

        #expect(producer.settingsUsed?.temperature == 0.2)
        #expect(producer.settingsUsed?.contextCap == 8192)
        #expect(producer.settingsUsed?.maxOutputTokens == 280)
    }
}
