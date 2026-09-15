import Foundation

/// What a decoder is allowed to do, shared by every engine.
///
/// These live here rather than in `RewriteCore` because they describe decoding,
/// not what a rewrite means, and because one copy is what stops `MLXEngine` and
/// `AppleFoundationEngine` from quietly diverging.
public enum EngineLimits {
    /// A rewrite should be the same sentence, better. Sampling variety is a
    /// liability here, not a feature.
    public static let temperature: Float = 0.2

    /// A memory cap this app imposes on itself, not a model limit:
    /// Qwen3-4B-Instruct-2507 reports `max_position_embeddings: 262144`.
    public static let contextCap = 8192

    /// Stops a one-line selection being cut off mid-word.
    public static let minimumOutputTokens = 64

    /// Stops a model that has started rambling from holding the panel open.
    public static let maximumOutputTokens = 768

    /// A rewrite runs a little longer than its input when grammar fixes expand
    /// a contraction, and essentially never longer than this.
    public static let outputScale = 1.4

    /// `min(max(64, inputTokens * 1.4), 768)`.
    ///
    /// The scaled value is rounded, not truncated. `1.4` is not exactly
    /// representable in binary, so `Double(200) * 1.4` is `279.999...` and an
    /// `Int(_:)` conversion would silently shave a token off every budget.
    public static func outputBudget(inputTokens: Int) -> Int {
        let scaled = Int((Double(inputTokens) * outputScale).rounded())
        return min(max(minimumOutputTokens, scaled), maximumOutputTokens)
    }
}
