/// Whether a generation stopped in the middle of a sentence.
///
/// The backstop for an engine that cannot say why it stopped. `MLXEngine`
/// refuses on `GenerationStop.budgetExhausted`, which is exact and needs no
/// inference; `AppleFoundationEngine` has nothing equivalent, because
/// `FoundationModels` exposes neither a stop reason nor a token count. This is
/// also what still catches a truncation if a future `mlx-swift-lm` stops
/// reporting completion info.
///
/// **Deliberately not a length ratio.** The obvious lower bound — "reject
/// output much shorter than its source" — rejects honest work. `Concise` is a
/// built-in style instructing *"Make this significantly shorter and more
/// direct"*, so a correct rewrite is routinely 40% of the original, which is
/// the same proportion a truncation produces. No threshold separates them,
/// because the difference is not how much text came back. It is where the
/// text stops.
public enum OutputCompleteness {
    /// Ends a sentence. Includes the CJK forms, since the model is told to
    /// preserve the input's language and will answer in it.
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Closes something rather than ending it. Stripped before the check on
    /// both sides, so a rewrite that correctly closes a quotation is not read
    /// as a fragment, and a source whose full stop is followed by a newline is
    /// still recognised as a complete sentence. The Markdown pair is here
    /// because `**Ready.**` is an ordinary thing for a model to emit.
    private static let closers: Set<Character> = [
        "\"", "'", ")", "]", "}", "»", "”", "’", "`", "*",
    ]

    /// The last character that carries sentence structure.
    private static func sentenceEnding(of text: String) -> Character? {
        var remaining = text[...]
        while let last = remaining.last, last.isWhitespace || closers.contains(last) {
            remaining = remaining.dropLast()
        }
        return remaining.last
    }

    /// True when the source was a complete sentence and the output is not.
    ///
    /// **Fails open in every other case, on purpose.** A source that is itself
    /// a fragment — a heading, a list item, a cell, half a line of code, the
    /// unpunctuated note someone is fixing — gives the rule nothing to compare
    /// against, and a guess there would refuse correct rewrites of a large
    /// share of what people actually select. The cost of the miss is bounded
    /// by `MLXEngine` refusing exactly on the default engine.
    public static func looksTruncated(_ output: String, source: String) -> Bool {
        guard let sourceEnd = sentenceEnding(of: source), terminators.contains(sourceEnd) else {
            return false
        }
        // Nothing came back at all. That is `OutputValidator.empty`, and
        // claiming it here as well would give one failure two names.
        guard let outputEnd = sentenceEnding(of: output) else { return false }
        return !terminators.contains(outputEnd)
    }
}
