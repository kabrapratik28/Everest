import Engines
import Foundation
import RewriteCore

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

    public static func live(for id: EngineID) -> any RewriteEngine {
        guard let spec = ModelCatalog.all.first(where: { $0.id == id }), !spec.repoID.isEmpty else {
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
