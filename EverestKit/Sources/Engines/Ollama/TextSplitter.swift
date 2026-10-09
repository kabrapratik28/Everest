import Foundation
import NaturalLanguage

/// One piece of a selection too long for a single request.
///
/// Only `body` reaches the model. `leading` and `trailing` are the user's own
/// whitespace around it, put back verbatim, so the joined rewrite keeps their
/// paragraphs and line breaks whatever the model does at a piece's edges.
public struct TextPiece: Equatable, Sendable {
    public let leading: String
    public let body: String
    public let trailing: String

    public init(leading: String, body: String, trailing: String) {
        self.leading = leading
        self.body = body
        self.trailing = trailing
    }
}

/// Splits a selection into pieces of at most `maxBytes` UTF-8 bytes each.
///
/// Boundaries, best first: a blank line, a sentence end, a line break, a
/// space. The best kind available is taken; among those, the one nearest an
/// even split, so two pieces come out about the same size rather than one
/// full and a short tail. There is no fifth kind: a word longer than a piece
/// returns nil, because a cut word, link or number is not something any
/// rewrite should be asked to repair.
public enum TextSplitter {
    public static func pieces(of text: String, maxBytes: Int) -> [TextPiece]? {
        guard maxBytes > 0 else { return nil }
        // Native UTF-8 storage, so the byte distances below are O(1). A
        // selection read through Accessibility can arrive as a bridged
        // NSString, where every distance would walk the whole string.
        var text = text
        text.makeContiguousUTF8()

        guard let contentStart = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return [TextPiece(leading: text, body: "", trailing: "")] }
        let contentEnd = text.index(after: last)
        let trailing = String(text[contentEnd...])
        func bytes(_ from: String.Index, _ to: String.Index) -> Int { text.utf8.distance(from: from, to: to) }

        // Code and links stay whole when they fit in a piece: a piece that
        // starts or ends inside one hands the model half a program or half a
        // URL. Code is found by the rule `EmDashes` uses, so both agree on
        // what code is.
        let code = (codeSpans(in: text) + linkRuns(in: text)).filter { bytes($0.lowerBound, $0.upperBound) <= maxBytes }
        let candidates = boundaries(in: text, content: contentStart..<contentEnd)
            .filter { cut in !code.contains { $0.lowerBound < cut.index && cut.index < $0.upperBound } }
        var pieces: [TextPiece] = []
        var leading = String(text[..<contentStart])
        var start = contentStart
        while bytes(start, contentEnd) > maxBytes {
            let remaining = bytes(start, contentEnd)
            let target = remaining / ((remaining + maxBytes - 1) / maxBytes)
            let window = candidates.filter { $0.index > start && bytes(start, $0.index) <= maxBytes }
            guard let tier = window.map(\.tier).min() else { return nil }
            let kind = window.filter { $0.tier == tier }
            let pastHalfway = kind.filter { bytes(start, $0.index) >= target / 2 }
            let cut = pastHalfway.min { abs(bytes(start, $0.index) - target) < abs(bytes(start, $1.index) - target) }
                ?? kind.last!

            // Within the content there is always more content after a
            // boundary, so the whitespace run after it ends before contentEnd.
            let next = text[cut.index...].firstIndex { !$0.isWhitespace } ?? contentEnd
            pieces.append(TextPiece(leading: leading, body: String(text[start..<cut.index]), trailing: String(text[cut.index..<next])))
            leading = ""
            start = next
        }
        pieces.append(TextPiece(leading: leading, body: String(text[start..<contentEnd]), trailing: trailing))
        return pieces
    }

    /// Text from a backtick to the next one, backticks included; an unpaired
    /// last backtick runs to the end. A fence's three backticks pair up the
    /// same way, so its body falls inside one span.
    static func codeSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var open: String.Index?
        for i in text.indices where text[i] == "`" {
            if let start = open {
                spans.append(start..<text.index(after: i))
                open = nil
            } else {
                open = i
            }
        }
        if let start = open { spans.append(start..<text.endIndex) }
        return spans
    }

    /// The space-free stretch around each "://": a link and whatever is
    /// glued to it. A full stop in a URL's path reads as a sentence end to
    /// `NLTokenizer` and as the URL's end to link detection, and without a
    /// space nothing tells a link that goes on from a sentence after one.
    static func linkRuns(in text: String) -> [Range<String.Index>] {
        text.ranges(of: "://").map { found in
            let start = text[..<found.lowerBound].lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
            let end = text[found.upperBound...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            return start..<end
        }
    }

    struct Boundary {
        let index: String.Index
        /// 0 blank line, 1 sentence end, 2 line break, 3 space. Lower is better.
        let tier: Int
    }

    /// Every place the content may be cut, sorted, one per index (the best
    /// kind wins where a sentence end and a whitespace run coincide). A
    /// boundary is the end of a stretch of content; the whitespace after it
    /// belongs to the piece before.
    static func boundaries(in text: String, content: Range<String.Index>) -> [Boundary] {
        var found: [String.Index: Int] = [:]
        func add(_ index: String.Index, _ tier: Int) { found[index] = min(found[index] ?? tier, tier) }

        var i = content.lowerBound
        while i < content.upperBound {
            guard text[i].isWhitespace else { i = text.index(after: i); continue }
            let run = i
            var newlines = 0
            while i < content.upperBound, text[i].isWhitespace {
                if text[i].isNewline { newlines += 1 }
                i = text.index(after: i)
            }
            add(run, newlines >= 2 ? 0 : newlines == 1 ? 2 : 3)
        }

        // ASCII " opens and closes alike: one after an odd number of them
        // closes, the way `EmDashes` reads backticks.
        let quotes = text.indices.filter { text[$0] == "\"" }
        func closesAQuote(_ i: String.Index) -> Bool { !quotes.prefix { $0 < i }.count.isMultiple(of: 2) }
        func opens(_ i: String.Index) -> Bool {
            "「『（〈《【〔〖〘〚“‘([".contains(text[i]) || (text[i] == "\"" && !closesAQuote(i))
        }
        func closes(_ i: String.Index) -> Bool {
            "」』）〉》】〕〗〙〛”’)]".contains(text[i]) || (text[i] == "\"" && closesAQuote(i))
        }
        // Chinese and Japanese end a sentence with a full-width mark and no
        // space, often inside closing quotes or brackets: 「今日は晴れです。」
        func endsFullWidthSentence(before end: String.Index) -> Bool {
            var mark = text.index(before: end)
            while mark > content.lowerBound, closes(mark) { mark = text.index(before: mark) }
            return "。！？".contains(text[mark])
        }
        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        sentences.enumerateTokens(in: content) { range, _ in
            var end = range.upperBound
            while end > range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            // It hands the next sentence its opening bracket or quote
            // (「…。」「 came back as one token), so the cut goes before it.
            while end > range.lowerBound, opens(text.index(before: end)) { end = text.index(before: end) }
            guard end > content.lowerBound, end < content.upperBound else { return true }
            // Followed by a space, or it is inside a word: `NLTokenizer` broke
            // `example.com/Q3.Report?Region=…` inside the link and
            // `../Reports.Q3/Overview` after "..". Not before a digit either:
            // it reads "Oct. 12." as two sentences. Lowercase is let through
            // on purpose: it already declines to break before a lowercase word
            // after a period, and the breaks it does make there are real
            // sentence ends in casual, all-lowercase writing.
            let spaced = text[end].isWhitespace || endsFullWidthSentence(before: end)
            let next = text[end...].first { !$0.isWhitespace }
            if spaced, next?.isNumber == false { add(end, 1) }
            return true
        }

        return found.map { Boundary(index: $0.key, tier: $0.value) }.sorted { $0.index < $1.index }
    }
}
