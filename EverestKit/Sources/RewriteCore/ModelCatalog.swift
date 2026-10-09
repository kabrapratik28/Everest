/// One entry in `ModelCatalog.all`: everything the app and its Settings UI
/// need to know about a model without having loaded it.
public struct ModelSpec: Sendable, Identifiable, Hashable {
    public var id: EngineID
    public let repoID: String        // "" for .apple: nothing to download
    public let displayName: String
    public let approxBytes: Int64
    public let blurb: String         // shown in Settings
    public let isDefault: Bool
    // Pinned commit SHA, never a branch. See RewriteCore/AGENTS.md.
    public let revision: String

    public init(id: EngineID, repoID: String, displayName: String, approxBytes: Int64, blurb: String, isDefault: Bool, revision: String) {
        self.id = id
        self.repoID = repoID
        self.displayName = displayName
        self.approxBytes = approxBytes
        self.blurb = blurb
        self.isDefault = isDefault
        self.revision = revision
    }
}

/// The fixed list of engines Settings offers. The MLX entries are the only
/// weights this app will ever download; Ollama runs whatever models the
/// user's own server has, named by that server, never by this file.
/// Never point an entry at a Qwen3.5 model: see RewriteCore/AGENTS.md.
public enum ModelCatalog {
    public static let all: [ModelSpec] = [
        ModelSpec(
            id: .qwen4B,
            repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B",
            approxBytes: 2_300_000_000,
            blurb: "Fast default. Text-only, non-thinking.",
            isDefault: true,
            revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
        ),
        ModelSpec(
            id: .qwen30B,
            repoID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            displayName: "Qwen3 30B-A3B",
            approxBytes: 17_200_000_000,
            blurb: "Higher quality. Larger download, more memory.",
            isDefault: false,
            revision: "e9675aa3ca5f900ccef55267914466d55ab325fa"
        ),
        ModelSpec(
            id: .apple,
            repoID: "",
            displayName: "Apple Intelligence",
            approxBytes: 0,
            blurb: "Zero-download, on-device. Guardrails may cut off ordinary text.",
            isDefault: false,
            // No repo, so no commit to pin — this is a fixed sentinel, not a
            // real revision. Non-empty only to satisfy the shared invariant.
            revision: "n/a-system-framework"
        ),
        ModelSpec(
            id: .ollama,
            repoID: "",
            displayName: "Ollama",
            approxBytes: 0,
            blurb: "Uses a model you already run in Ollama. Nothing to download here.",
            isDefault: false,
            // The same sentinel arrangement as Apple's: the user's server
            // owns these models, so there is nothing of ours to pin.
            revision: "n/a-ollama"
        ),
    ]
}
