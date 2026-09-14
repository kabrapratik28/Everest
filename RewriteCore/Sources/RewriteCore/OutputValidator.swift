import Foundation

/// Why a candidate rewrite was rejected. `lengthRatio` carries the actual
/// ratio so a caller can log or display it without recomputing it.
public enum ValidationFailure: Error, Equatable, Sendable {
    case empty
    case lengthRatio(Double)  // > 3.0 of source
}

/// Cleans and sanity-checks raw model output before it is ever shown to the
/// user or used to replace anything. See AGENTS.md for the failure modes
/// this guards against.
public enum OutputValidator {
    /// Strips a leading conversational preamble (e.g. "Sure! Here's an
    /// improved version:\n\n"), stray `<selected_text>` wrapper tags the
    /// model echoed back, and one layer of wrapping quotes.
    public static func clean(_ raw: String) -> String {
        var text = raw

        text = stripLeadingPreamble(text)
        text = text.replacingOccurrences(of: "<selected_text>", with: "")
        text = text.replacingOccurrences(of: "</selected_text>", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `clean()`, then rejects a result that is empty or wildly longer than
    /// the source. Both are common small-model failure modes: answering a
    /// question found in the selection instead of rewriting it, repeating
    /// itself, or trailing off into unrelated commentary.
    public static func validate(_ raw: String, source: String) -> Result<String, ValidationFailure> {
        let cleaned = clean(raw)

        guard !cleaned.isEmpty else {
            return .failure(.empty)
        }

        let sourceLength = source.count
        if sourceLength > 0 {
            let ratio = Double(cleaned.count) / Double(sourceLength)
            if ratio > 3.0 {
                return .failure(.lengthRatio(ratio))
            }
        }

        return .success(cleaned)
    }

    // MARK: - Preamble stripping

    /// Lead-in words models commonly use before the colon in a preamble
    /// line, e.g. "Sure! Here's an improved version:".
    private static let preambleLeadIns = [
        "sure", "of course", "certainly", "absolutely", "okay", "ok", "great", "here",
    ]

    private static func stripLeadingPreamble(_ text: String) -> String {
        guard let blankLineRange = text.range(of: "\n\n") else { return text }
        let firstLine = text[text.startIndex..<blankLineRange.lowerBound]

        guard
            !firstLine.contains("\n"),
            firstLine.count <= 120,
            firstLine.trimmingCharacters(in: .whitespaces).hasSuffix(":")
        else { return text }

        let lower = firstLine.lowercased()
        guard preambleLeadIns.contains(where: { lower.contains($0) }) else { return text }

        return String(text[blankLineRange.upperBound...])
    }

    // MARK: - Quote stripping

    private static let wrappingQuotePairs: [(Character, Character)] = [
        ("\"", "\""),
        ("\u{201C}", "\u{201D}"),  // curly “ ”
    ]

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        for pair in wrappingQuotePairs where first == pair.0 && last == pair.1 {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
