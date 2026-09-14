import Foundation

/// Static facts about one downloadable (or built-in) engine, shown in
/// Settings so the user can make an informed choice before a multi-gigabyte
/// download starts.
public struct ModelSpec: Sendable, Identifiable, Hashable {
    public var id: EngineID
    public let repoID: String  // "" for .apple
    public let displayName: String
    public let approxBytes: Int64
    public let blurb: String  // shown in Settings
    public let isDefault: Bool

    // A public struct's memberwise init defaults to internal, which leaves a
    // public type unconstructable from another module (the app target,
    // tests) unless one is written out by hand.
    public init(
        id: EngineID,
        repoID: String,
        displayName: String,
        approxBytes: Int64,
        blurb: String,
        isDefault: Bool
    ) {
        self.id = id
        self.repoID = repoID
        self.displayName = displayName
        self.approxBytes = approxBytes
        self.blurb = blurb
        self.isDefault = isDefault
    }
}

/// The complete, fixed list of engines this app will ever offer. See
/// AGENTS.md for why this list must never grow a Qwen3.5 entry.
public enum ModelCatalog {
    public static let all: [ModelSpec] = [
        ModelSpec(
            id: .qwen4B,
            repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B (Fast)",
            approxBytes: 2_300_000_000,
            blurb:
                "The default. About a 2.3 GB download, then everything runs on this Mac. Rewrites a paragraph in a couple of seconds on Apple Silicon. Handles grammar, clarity, and tone changes well; a very long or nuanced passage is where it's most likely to miss something a larger model would catch. Right choice for almost everyone.",
            isDefault: true
        ),
        ModelSpec(
            id: .qwen30B,
            repoID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            displayName: "Qwen3 30B (Quality)",
            approxBytes: 17_200_000_000,
            blurb:
                "Better judgment on longer or trickier text, at the cost of a much bigger download (about 17 GB) and slower generation, roughly 5 seconds per paragraph instead of 2. It's a mixture-of-experts model, so while resident it needs about 18-20 GB of free memory, comfortable on a 48 GB+ Mac and unworkable on 16-24 GB. Pick this if you have the RAM and disk and want the best rewrite quality this app offers.",
            isDefault: false
        ),
        ModelSpec(
            id: .apple,
            repoID: "",
            displayName: "Apple Intelligence",
            approxBytes: 0,
            blurb:
                "No download, no disk space, uses the on-device model macOS already provides. Fast and free, but Apple's safety guardrails can refuse or cut off ordinary text, a sentence mentioning a death, routine political content, and similar, with a vague error, and those guardrails cannot be turned off. Good as a zero-setup option; a poor fit if you regularly write about sensitive topics.",
            isDefault: false
        ),
    ]
}
