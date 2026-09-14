import Foundation

/// Identifies one of the three engines this app will ever load. The raw
/// values are stable identifiers used for persistence (`AppSettings`) and
/// for the on-disk model folder name; do not change an existing raw value
/// once shipped, or a user's saved preference silently stops matching.
public enum EngineID: String, Sendable, CaseIterable, Codable {
    case qwen4B  = "qwen3-4b-instruct-2507-4bit"
    case qwen30B = "qwen3-30b-a3b-instruct-2507-4bit"
    case apple   = "apple-foundation-models"
}

/// One rewrite request: the untrusted source text and the style to apply.
/// See AGENTS.md for why `text` is never trimmed or normalized anywhere
/// upstream of this point.
public struct RewriteRequest: Sendable {
    public let text: String
    public let preset: Preset

    public init(text: String, preset: Preset) {
        self.text = text
        self.preset = preset
    }
}

/// Cumulative snapshots, not deltas. Apple's API is snapshot-shaped and
/// snapshots survive a dropped UI update; deltas do not.
public enum RewriteEvent: Sendable {
    case preparing(progress: Double?)
    case outputSnapshot(String)
    case finished(String)
}

/// Whether an engine can run a request right now without further setup.
public enum EngineAvailability: Sendable, Equatable {
    case ready
    case needsDownload(bytes: Int64)
    case unavailable(reason: String)
}

/// What every rewrite backend implements, whether it is a downloaded MLX
/// model or the system's Apple Intelligence model. See AGENTS.md for why
/// this protocol exists even though only two conforming types will ever
/// ship.
public protocol RewriteEngine: Sendable {
    var id: EngineID { get }
    func availability() async -> EngineAvailability
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error>
    func cancel() async
}
