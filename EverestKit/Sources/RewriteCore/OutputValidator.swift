import Foundation

/// Why a rewrite got rejected before it could replace a user's selection.
public enum ValidationFailure: Error, Equatable, Sendable {
    case empty
    case lengthRatio(Double)
}

/// Cleans and sanity-checks raw model output before it can replace a user's
/// selection. See RewriteCore/AGENTS.md: this is the second layer of defense
/// behind PromptBuilder's safety frame, catching output that got hijacked or
/// otherwise stopped looking like a rewrite of the input.
///
/// **Everything here removes the model's packaging, never the user's
/// content**, and the two are told apart by comparing against the source.
/// Both unwrapping rules once failed that test and silently edited people's
/// writing: every `<selected_text>` occurrence was deleted wherever it
/// appeared, and any outer pair of double quotes was stripped — which the
/// safety frame explicitly asks the model to preserve. A tidy-up that damages
/// correct input is a worse bug than the tic it was tidying.
public enum OutputValidator {
    /// Conversational preambles some models prepend despite instructions not to.
    private static let preambles = [
        "Sure! Here's an improved version:\n\n",
    ]

    /// The prompt's wrapper, echoed back around the answer.
    ///
    /// Two deliberate narrowings. It matches only around the **whole** output,
    /// because a tag in the middle of a rewrite is the user's sentence, not
    /// our envelope. And it requires the **per-prompt id** `PromptBuilder`
    /// generates: the model is never shown a bare `<selected_text>`, so a bare
    /// one in the output can only have come from the user's own text.
    ///
    /// That id is read as a pattern rather than threaded through from
    /// `PromptBuilder`. Carrying the exact value would mean passing it through
    /// both engines' `stream` and into `validate` — four files across three
    /// modules — to catch an occasional cosmetic tic. This is a tidy-up, not a
    /// guard; containment is structural and lives in `PromptBuilder`.
    /// Computed, not a `static let`: `Regex` is not `Sendable`, so a stored
    /// one is a concurrency error under Swift 6. Built once per rewrite, not
    /// per token.
    private static var envelope: Regex<(Substring, Substring)> {
        /\s*<selected_text_[0-9a-fA-F]+>(.*)<\/selected_text_[0-9a-fA-F]+>\s*/
            .dotMatchesNewlines()
    }

    public static func clean(_ raw: String, source: String) -> String {
        var result = raw
        for preamble in preambles where result.hasPrefix(preamble) {
            result.removeFirst(preamble.count)
            break
        }
        if let match = result.wholeMatch(of: envelope) {
            // Trimmed because the prompt puts the text on its own line, so
            // the newlines either side belong to the envelope rather than to
            // the rewrite.
            result = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return unquoted(result, source: source)
    }

    /// Removes a pair of quotes the *model* put around its answer, and leaves
    /// alone a pair the user wrote.
    ///
    /// The old rule stripped any outer pair, so a source holding two quoted
    /// phrases came back **unbalanced** — `"A" and "B"` became `A" and "B`.
    /// Asking whether the source was quoted too is what separates the model
    /// packaging its reply from the user quoting someone.
    private static func unquoted(_ text: String, source: String) -> String {
        guard isQuoted(text), !isQuoted(source) else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func isQuoted(_ text: String) -> Bool {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"")
    }

    /// A genuine rewrite essentially never triples the input's length; past
    /// that, treat it as a runaway generation or a hijacked response rather
    /// than a rewrite. See RewriteCore/AGENTS.md, "The five constants."
    private static let maxLengthRatio = 3.0

    /// `clean()` then reject output that isn't a plausible rewrite.
    public static func validate(_ raw: String, source: String) -> Result<String, ValidationFailure> {
        let cleaned = clean(raw, source: source)
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
