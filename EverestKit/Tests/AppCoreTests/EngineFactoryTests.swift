import RewriteCore
import os
import Testing

@testable import AppCore
@testable import Engines

/// **The two tests that share the process-wide registry, run one at a time.**
///
/// `EngineFactory.registry` holds one weight-bearing engine, by design:
/// asking for a second evicts the first, which is what keeps peak memory at
/// 1x. That makes any two tests touching it order-dependent, and swift-testing
/// runs tests in parallel — `everyCatalogEntryBuildsItsOwnEngine` walks the
/// whole catalog, so a `.qwen30B` build landing between the two `live(for:
/// .qwen4B)` calls below evicts the engine whose identity is being asserted.
///
/// It sat latent until an unrelated test was added to this bundle and the
/// schedule shifted; the failure was in the eviction rule, which was behaving
/// exactly as documented. The other tests here each build their own
/// `EngineRegistry` and need no serialising.
@Suite(.serialized)
struct GlobalEngineRegistryTests {
/// Which concrete engine backs which id is a branch, so it lives here rather
/// than in the app target. Getting it wrong is silent: an `MLXEngine` built
/// for `.apple` would carry an empty `repoID` and fail at download time with
/// a malformed-repository error, several screens away from the mistake.
@Test("every catalog id builds the engine that claims that id")
func everyCatalogEntryBuildsItsOwnEngine() {
    for spec in ModelCatalog.all {
        #expect(EngineFactory.live(for: spec.id).id == spec.id)
    }
}

/// The weights must survive from one rewrite to the next.
///
/// `RewriteCoordinator.run` asks for an engine once per transaction, so a
/// factory that builds a fresh `MLXTokenProducer` on every call hands each
/// hotkey press an empty `LoadedModel`. `prepare` then short-circuits the
/// *download* on the `.ready` marker and still runs `loadContainer`, re-reading
/// 2.3 GB from disk before the first token. Nothing downstream catches it:
/// `LLMModelFactory.loadContainer(from:using:)` has no cache of its own.
///
/// Sharing the producer is the whole fix, so the producer is what this asserts.
@Test("the same id hands back one producer, so the weights are read once")
func liveKeepsOneProducerPerID() throws {
    let first = try #require(EngineFactory.live(for: .qwen4B) as? MLXEngine)
    let second = try #require(EngineFactory.live(for: .qwen4B) as? MLXEngine)

    #expect(try #require(first.producer as? MLXTokenProducer)
        === #require(second.producer as? MLXTokenProducer))
}
}

/// Deleting a model has to return the memory, not just the disk.
///
/// Keeping the engine alive is the point of the registry, so a delete has to
/// be able to take it away again. Otherwise "Delete model" frees 2.3 GB of
/// disk and nothing else: the retained producer still holds the weights and
/// will still generate from them, while `availability()` reads the missing
/// `.ready` marker and reports `needsDownload`.
@Test("weights leaving the disk drop the engine that was holding them")
func deletedWeightsDropTheCachedEngine() throws {
    let onDisk = OSAllocatedUnfairLock(initialState: true)
    let registry = EngineRegistry(
        build: { StubEngine(id: $0) },
        hasWeights: { _ in onDisk.withLock { $0 } }
    )
    let loaded = try #require(registry.engine(for: .qwen4B) as? StubEngine)

    onDisk.withLock { $0 = false }

    #expect(try #require(registry.engine(for: .qwen4B) as? StubEngine) !== loaded)
}

/// A download must not be evicted by the rewrite the user starts while waiting.
///
/// `ModelSettingsModel.download` takes an engine and then transfers for
/// minutes, holding it locally. Its weights are absent for that whole window,
/// so treating "no weights on disk" as a deletion would replace the registry's
/// copy with a cold engine every time anything else asked — a hotkey press, a
/// Settings refresh. The warm one then dies when `download` returns and the
/// first rewrite re-reads all 2.3 GB, which is the bug this file exists to
/// stop. An entry is only worth dropping once it has been seen with weights.
///
/// This is also what keeps the test above honest on a machine that has never
/// downloaded the model.
@Test("the engine a download warms is the one kept, not one built during it")
func theEngineWarmedByADownloadIsKept() throws {
    let onDisk = OSAllocatedUnfairLock(initialState: false)
    let registry = EngineRegistry(
        build: { StubEngine(id: $0) },
        hasWeights: { _ in onDisk.withLock { $0 } }
    )
    let downloading = try #require(registry.engine(for: .qwen4B) as? StubEngine)

    #expect(try #require(registry.engine(for: .qwen4B) as? StubEngine) === downloading)

    onDisk.withLock { $0 = true }

    #expect(try #require(registry.engine(for: .qwen4B) as? StubEngine) === downloading)
}

/// Download a model, change your mind, and the memory goes too.
///
/// The exemption above is why this needs saying separately. An entry born
/// before its weights is exempt from eviction, and it has to *stop* being
/// exempt once they land, or a model downloaded and deleted in one session
/// frees the disk and none of the 2.3 GB. Restarting the app would hide it,
/// which is the kind of bug that gets closed as unreproducible.
///
/// The lookup in the middle is not scene-setting: `ModelSettingsModel.download`
/// ends with `refresh()`, and `refresh` asks for every engine.
///
/// Test-first had no failing ordering to offer here — this is a third state in
/// a sequence whose halves the two tests above already pin — so it was proven
/// by deleting the promotion and watching this test, alone, fail.
@Test("a model downloaded and then deleted in one session lets its engine go")
func weightsArrivingThenLeavingDropTheEngine() throws {
    let onDisk = OSAllocatedUnfairLock(initialState: false)
    let registry = EngineRegistry(
        build: { StubEngine(id: $0) },
        hasWeights: { _ in onDisk.withLock { $0 } }
    )
    let downloaded = try #require(registry.engine(for: .qwen4B) as? StubEngine)

    onDisk.withLock { $0 = true }
    _ = registry.engine(for: .qwen4B)
    onDisk.withLock { $0 = false }

    #expect(try #require(registry.engine(for: .qwen4B) as? StubEngine) !== downloaded)
}

/// Never `~/.cache/huggingface`.
///
/// `HubCache.default` is shared with every other tool on the machine, which
/// Settings could neither size honestly nor safely delete — "Delete model"
/// would remove weights some other program is using. This app owns its own
/// cache root under Application Support and deletes only inside it.
@Test("models live in a directory this app owns, not the shared Hugging Face cache")
func theModelStoreIsPrivateToThisApp() {
    let root = EngineFactory.modelStoreRoot

    let path = root.path(percentEncoded: false)

    #expect(Array(root.pathComponents.suffix(2)) == ["Everest", "Models"])
    #expect(path.contains("Application Support"))
    #expect(!path.contains(".cache/huggingface"))
}

/// Only one MLX engine stays resident. Switching model releases the last.
///
/// The registry kept an entry per `EngineID` with no cap, and its only
/// eviction was pull-based on the weights leaving the disk — which is
/// *deletion*, not *switching*. So picking 30B after 4B retained both
/// containers, and switching back retained 17.2 GB alongside.
///
/// **That is what defeats the memory gate.** `EngineEligibility` asks whether
/// a model fits *in isolation*, so a 24 GB Mac is allowed to choose 17.2 GB —
/// correct only if 2.3 GB is not still resident beside it. The gate and the
/// registry each look right alone and are wrong together, which is why this
/// is the registry's test and not the gate's.
///
/// Apple's engine is exempt: it holds no weights of ours, so evicting it
/// frees nothing and rebuilding it costs nothing.
@Test("switching model releases the previous engine, so two sets of weights are never resident")
func switchingModelEvictsThePreviousEngine() throws {
    let built = OSAllocatedUnfairLock(initialState: [EngineID]())
    let registry = EngineRegistry(
        build: { id in
            built.withLock { $0.append(id) }
            return StubEngine(id: id)
        },
        hasWeights: { _ in true }
    )

    _ = registry.engine(for: .qwen4B)
    // Positive control: asking twice for the same id must *not* rebuild, or
    // this test would pass against a registry that caches nothing at all —
    // which is the regression the registry exists to prevent.
    _ = registry.engine(for: .qwen4B)
    #expect(built.withLock { $0 } == [.qwen4B], "the registry stopped caching")

    _ = registry.engine(for: .qwen30B)
    // Coming back must rebuild, which is the observable form of "the 4B
    // container was released when 30B took its place".
    _ = registry.engine(for: .qwen4B)

    #expect(built.withLock { $0 } == [.qwen4B, .qwen30B, .qwen4B])
}
