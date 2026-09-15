import Engines
import Foundation
import RewriteCore
import Synchronization

/// Keeps one engine per `EngineID` alive across rewrites.
///
/// An engine is not a cheap thing to rebuild, because its `MLXTokenProducer`
/// carries the loaded weights. A new one starts with an empty `LoadedModel`,
/// and `MLXEngine.prepare` then re-reads 2.3 GB from disk however recently
/// that same model was loaded — the `.ready` marker short-circuits the
/// download, never the load.
///
/// `build` runs inside the lock so that two hotkey presses half a second apart
/// cannot both miss and both start a load, which is the same reason
/// `LoadedModel` is an actor. It is safe to hold the lock across it because
/// building is allocation only: nothing is read from disk until `prepare`.
final class EngineRegistry: Sendable {
    private struct Entry {
        let engine: any RewriteEngine
        /// Set once this entry's weights have been seen on disk.
        ///
        /// Until then there is nothing a deletion could free, and dropping the
        /// entry would throw away the engine a download is in the middle of
        /// warming.
        var sawWeights: Bool
    }

    private let entries = Mutex<[EngineID: Entry]>([:])
    private let build: @Sendable (EngineID) -> any RewriteEngine
    private let hasWeights: @Sendable (EngineID) -> Bool

    init(
        build: @escaping @Sendable (EngineID) -> any RewriteEngine,
        hasWeights: @escaping @Sendable (EngineID) -> Bool
    ) {
        self.build = build
        self.hasWeights = hasWeights
    }

    /// The engine for `id`, built once and then reused.
    ///
    /// Rebuilt only once the weights it was seen holding have left the disk,
    /// which is how "Delete model" gets the memory back as well as the
    /// gigabytes.
    func engine(for id: EngineID) -> any RewriteEngine {
        // Off the lock: this is a `FileManager` call.
        let onDisk = hasWeights(id)

        return entries.withLock { entries in
            if let entry = entries[id] {
                let weightsWereDeleted = entry.sawWeights && !onDisk
                if !weightsWereDeleted {
                    if onDisk { entries[id] = Entry(engine: entry.engine, sawWeights: true) }
                    return entry.engine
                }
            }

            let engine = build(id)
            entries[id] = Entry(engine: engine, sawWeights: onDisk)
            return engine
        }
    }
}

/// Builds the real engines.
///
/// In `AppCore` rather than the app target because choosing between them is a
/// branch, and a branch in the app target has no test runner. Nothing here
/// decides *when* to use an engine — that is `AppSettings.engineID`, read per
/// transaction by the coordinator.
public enum EngineFactory {
    /// `~/Library/Application Support/Everest/Models/`.
    ///
    /// Never `HubCache.default` (`~/.cache/huggingface`), which is shared with
    /// every other tool on the machine: Settings could not honestly report its
    /// size, and "Delete model" would remove weights something else is using.
    public static let modelStoreRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Everest", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    private static let registry = EngineRegistry(
        build: { make(for: $0) },
        hasWeights: { weightsInstalled(for: $0) }
    )

    /// The engine for `id`. The same one each time, see `EngineRegistry`.
    public static func live(for id: EngineID) -> any RewriteEngine {
        registry.engine(for: id)
    }

    /// The catalog entry for `id`, or `nil` for an engine with no weights of
    /// ours. An empty `repoID` is Apple's system model.
    private static func downloadable(_ id: EngineID) -> ModelSpec? {
        guard let spec = ModelCatalog.all.first(where: { $0.id == id }), !spec.repoID.isEmpty else {
            return nil
        }
        return spec
    }

    /// Whether `id`'s pinned snapshot is on disk right now.
    ///
    /// The snapshot rather than the `.ready` marker: the marker is cleared at
    /// the *start* of a re-download, which would read as a deletion and throw
    /// away an engine mid-transfer. Apple's engine holds no weights of ours,
    /// so there is nothing for it to lose.
    private static func weightsInstalled(for id: EngineID) -> Bool {
        guard let spec = downloadable(id) else { return false }
        return ModelStore(root: modelStoreRoot)
            .installedSnapshot(for: spec.repoID, revision: spec.revision) != nil
    }

    private static func make(for id: EngineID) -> any RewriteEngine {
        guard let spec = downloadable(id) else {
            // No repository means Apple's system model: nothing to download,
            // nothing to pin, and availability is a System Settings toggle.
            return AppleFoundationEngine(system: SystemLanguageModelAdapter())
        }

        let store = ModelStore(root: modelStoreRoot)
        // The `spec:` initializer, never the long one. It is what takes the
        // repository *and* the pinned commit from the single place recording
        // which weights were actually tested, so a call site here cannot
        // quietly substitute a branch — see root `AGENTS.md` §5.
        return MLXEngine(
            spec: spec,
            store: store,
            fetcher: HubModelFetcher(),
            producer: MLXTokenProducer()
        )
    }
}
