import Foundation
import RewriteCore

/// Whether this Mac can run a given engine, and what to use when it cannot.
///
/// Separate from the row that renders it, because **the row is a view and the
/// choice outlives it**. `engineID` is persisted, read straight out of
/// `UserDefaults` at launch and handed to `RewriteCoordinator`; a disabled
/// row does not exist at that moment. A 30B choice made on a large Mac, or
/// restored onto a smaller one, or written before this gate existed, reaches
/// the engine having met no gate at all — and then every hotkey press loads
/// 17.2 GB into 16 GB of RAM.
///
/// Same failure as the radio button that was a picture of a control: whatever
/// looks like the gate is not the gate unless the value has to pass it.
public enum EngineEligibility {
    /// Headroom for the OS, the app and the KV cache. A fixed margin rather
    /// than a ratio — what the rest of the system needs does not scale with
    /// the model — and without it a model that exactly filled RAM would
    /// count as fitting and still thrash.
    static let memoryHeadroom: UInt64 = 4 * 1024 * 1024 * 1024

    /// Whether the weights plus headroom fit in physical memory.
    ///
    /// Apple's engine holds no weights of ours (`approxBytes == 0`), so
    /// memory never disqualifies it; whether it can run at all is a System
    /// Settings toggle reported through `availability`.
    public static func fits(_ spec: ModelSpec, physicalMemory: UInt64) -> Bool {
        UInt64(max(spec.approxBytes, 0)) + memoryHeadroom <= physicalMemory
    }

    /// The engine to actually use, given what this machine can hold.
    ///
    /// Falls back to the catalog default rather than to Apple's engine, which
    /// may not exist here. If even the default does not fit there is nothing
    /// better to offer, so it is returned anyway — a wrong-but-smallest
    /// choice beats refusing to rewrite at all.
    public static func resolved(_ id: EngineID, physicalMemory: UInt64) -> EngineID {
        let fallback = ModelCatalog.all.first(where: \.isDefault)?.id ?? id
        guard let spec = ModelCatalog.all.first(where: { $0.id == id }) else { return fallback }
        return fits(spec, physicalMemory: physicalMemory) ? id : fallback
    }
}
