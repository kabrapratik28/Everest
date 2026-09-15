import RewriteCore
import Synchronization
import Testing

@testable import AppCore
@testable import Engines

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

/// Deleting a model has to return the memory, not just the disk.
///
/// Keeping the engine alive is the point of the registry, so a delete has to
/// be able to take it away again. Otherwise "Delete model" frees 2.3 GB of
/// disk and nothing else: the retained producer still holds the weights and
/// will still generate from them, while `availability()` reads the missing
/// `.ready` marker and reports `needsDownload`.
@Test("weights leaving the disk drop the engine that was holding them")
func deletedWeightsDropTheCachedEngine() throws {
    let onDisk = Mutex(true)
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
    let onDisk = Mutex(false)
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
    let onDisk = Mutex(false)
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
