import Foundation

/// A generation that cannot be offered to the user as a rewrite.
///
/// Shared by both engines, because both can produce one and the remedy is the
/// same. Deliberately an error rather than a `RewriteEvent`: the coordinator
/// writes whatever reaches `.finished`, so the only safe way to say "this is
/// not a rewrite" is to never get there.
public enum GenerationError: Error, Equatable, Sendable {
    /// The decoder stopped because it ran out of output budget, so what came
    /// back is the beginning of a rewrite rather than a rewrite.
    case truncated

    /// The remedy, in words the user can act on.
    ///
    /// It says *nothing was changed* on purpose. The failure the user is being
    /// told about is one whose whole point is that their text survived it, and
    /// an error message that does not say so reads as "your document is now in
    /// an unknown state".
    public var message: String {
        switch self {
        case .truncated:
            "That passage is too long for this model to rewrite in one piece. Nothing was changed — select a shorter passage and try again."
        }
    }
}

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

    /// A rewrite runs a little longer than its input when grammar fixes expand
    /// a contraction. **This is the guard against a rambling generation**, and
    /// it is the only one that needs to be: it scales, so it stays
    /// proportionate at every input size.
    ///
    /// **It is not true of every preset, and saying so here was wrong.** The
    /// built-in `Expand` style asks for more supporting detail, and because
    /// the prompt's fixed overhead shrinks as a share of the budget, the
    /// effective ceiling *tightens* with length: roughly 3× the selection at
    /// 500 characters, 1.8× at 2,000, 1.6× at 4,000. An expansion past that
    /// hits `maxOutputTokens` and is refused as `GenerationError.truncated`.
    ///
    /// Left at 1.4 deliberately. A per-preset multiplier cannot work, for the
    /// reason that retired the 3× validator ratio: intent is not in the
    /// length, and the only thing carrying intent is `preset.instruction`,
    /// which the user edits freely. Raising this globally is the one real
    /// lever and it is a product call — it buys `Expand` room at the cost of
    /// letting a rambling generation run that much longer before the same
    /// refusal. Unlike the ratio this fails *visibly*, with the user's text
    /// untouched and a sentence telling them to select less, so it is a
    /// capability limit rather than a correctness defect.
    public static let outputScale = 1.4

    /// `min(max(64, inputTokens * 1.4), contextCap - inputTokens)`.
    ///
    /// The scaled value is rounded, not truncated. `1.4` is not exactly
    /// representable in binary, so `Double(200) * 1.4` is `279.999...` and an
    /// `Int(_:)` conversion would silently shave a token off every budget.
    ///
    /// **The ceiling is derived, never a constant of its own.** It used to be
    /// a flat 768, chosen to bound how long the panel stays open, and that
    /// number was never reconciled with the 8,000-character capture cap in
    /// `TextBridge`. From about 550 input tokens up — a selection of roughly
    /// 2,200 characters — 768 was below what a faithful rewrite needs, so the
    /// decoder stopped at `maxTokens` mid-word and the half-rewrite was
    /// written over the user's paragraph. Nothing downstream could catch it:
    /// `OutputValidator` rejects output that is *too long* and has no lower
    /// bound. Two independently reasonable constants, silently destroying text
    /// where they met.
    ///
    /// `contextCap - inputTokens` is the honest ceiling because it is the one
    /// real limit: the prompt and the generation share the KV cache, so this
    /// is also what stops `maxTokens` overrunning the `maxKVSize` the same
    /// settings ask for. Past `contextCap / 2` it forces a budget smaller than
    /// the input, and those selections are **refused** by the stop-reason
    /// check in `MLXEngine` rather than quietly truncated.
    public static func outputBudget(inputTokens: Int) -> Int {
        let scaled = Int((Double(inputTokens) * outputScale).rounded())
        let headroom = max(minimumOutputTokens, contextCap - inputTokens)
        return min(max(minimumOutputTokens, scaled), headroom)
    }
}
