/// Identifies which model backs a rewrite. Raw values are stable, persisted
/// identifiers (used as UserDefaults values and dictionary keys) — do not
/// change one without a migration.
public enum EngineID: String, Sendable, CaseIterable, Codable {
    case qwen4B  = "qwen3-4b-instruct-2507-4bit"
    case qwen30B = "qwen3-30b-a3b-instruct-2507-4bit"
    case apple   = "apple-foundation-models"
}

// NOTE on the four declarations below: pure shape (stored properties and a
// protocol with no default implementation), zero branching logic, so there is
// no behaviour for a unit test to drive out — the Iron Law's own "honest
// exception" (root AGENTS.md §0) for things that can't be meaningfully unit
// tested. They exist un-test-driven, deliberately and only, because Engines,
// Overlay, and TextBridge are being written against this exact contract
// concurrently and need it to compile. See RewriteCore/AGENTS.md.

public struct RewriteRequest: Sendable {
    public let text: String
    public let preset: Preset

    public init(text: String, preset: Preset) {
        self.text = text
        self.preset = preset
    }
}

/// Cumulative snapshots, not deltas. Apple's API is snapshot-shaped and
/// snapshots survive a dropped UI update; deltas do not. See RewriteCore/AGENTS.md.
public enum RewriteEvent: Sendable {
    case preparing(progress: Double?)
    case outputSnapshot(String)
    case finished(String)
}

public enum EngineAvailability: Sendable, Equatable {
    case ready
    case needsDownload(bytes: Int64)
    case unavailable(reason: String)
}

public protocol RewriteEngine: Sendable {
    var id: EngineID { get }
    func availability() async -> EngineAvailability
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error>
    func cancel() async
}
