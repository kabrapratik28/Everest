/// Why a rewrite got rejected before it could replace a user's selection.
public enum ValidationFailure: Error, Equatable, Sendable {
    case empty
    case lengthRatio(Double)
}

/// Cleans and sanity-checks raw model output before it can replace a user's
/// selection. See RewriteCore/AGENTS.md: this is the second layer of defense
/// behind PromptBuilder's safety frame, catching output that got hijacked or
/// otherwise stopped looking like a rewrite of the input.
public enum OutputValidator {
    /// Conversational preambles some models prepend despite instructions not to.
    private static let preambles = [
        "Sure! Here's an improved version:\n\n",
    ]

    public static func clean(_ raw: String) -> String {
        var result = raw
        for preamble in preambles where result.hasPrefix(preamble) {
            result.removeFirst(preamble.count)
            break
        }
        result = result.replacingOccurrences(of: "<selected_text>", with: "")
        result = result.replacingOccurrences(of: "</selected_text>", with: "")
        if result.count >= 2, result.hasPrefix("\""), result.hasSuffix("\"") {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    /// A genuine rewrite essentially never triples the input's length; past
    /// that, treat it as a runaway generation or a hijacked response rather
    /// than a rewrite. See RewriteCore/AGENTS.md, "The five constants."
    private static let maxLengthRatio = 3.0

    /// `clean()` then reject output that isn't a plausible rewrite.
    public static func validate(_ raw: String, source: String) -> Result<String, ValidationFailure> {
        let cleaned = clean(raw)
        if cleaned.isEmpty {
            return .failure(.empty)
        }
        let ratio = Double(cleaned.count) / Double(source.count)
        if ratio > maxLengthRatio {
            return .failure(.lengthRatio(ratio))
        }
        return .success(cleaned)
    }
}
