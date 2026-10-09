import Foundation
import Testing

@testable import Engines

/// Splitting a selection too long for an Ollama model's context window.
///
/// Every piece's `leading + body + trailing` joins back into the selection
/// byte for byte, so the rewrite keeps the user's paragraphs. Compared as
/// UTF-8 because Swift's `String ==` treats canonically equivalent text as
/// equal, which would let a normalising splitter pass.
@Suite("TextSplitter")
struct TextSplitterTests {
    static func joined(_ pieces: [TextPiece]) -> [UInt8] {
        Array(pieces.map { $0.leading + $0.body + $0.trailing }.joined().utf8)
    }

    static let japanese = "昨夜数字を確認しました。火曜日よりも状況ははっきりしています。減少は一つのコホートに集中しています！本当ですか？"

    @Test("pieces join back into the selection byte for byte, each body trimmed and within the limit")
    func piecesJoinBackExactly() throws {
        let prose = "Thanks for the update. I reviewed the numbers last night and the picture is clearer than it was on Tuesday. The drop is concentrated in one cohort. We would rather hold the launch a week."
        let samples = [
            prose,
            "First paragraph line one.\r\nLine two.\r\n\r\nSecond paragraph here.\r\n\r\n\r\nThird one.",
            "Name:\tPratik\nRole:\tLead\n\n\tIndented paragraph with a tab at the start.",
            String(repeating: "Family 👨‍👩‍👧‍👦 trip. Thumbs 👍🏽 up! Flags 🇮🇳🇺🇸 everywhere. ", count: 4),
            String(repeating: Self.japanese, count: 3),
            "  \n Hello there. How are you?\n\n",
            String(repeating: prose + "\n\n" + Self.japanese + "\r\n", count: 14),
        ]
        for sample in samples {
            for maxBytes in [60, 200, 10_000] {
                let pieces = try #require(TextSplitter.pieces(of: sample, maxBytes: maxBytes))
                #expect(Self.joined(pieces) == Array(sample.utf8), "\(sample.prefix(20)) at \(maxBytes)")
                for piece in pieces {
                    #expect(piece.body.utf8.count <= maxBytes)
                    #expect(piece.body.first?.isWhitespace != true && piece.body.last?.isWhitespace != true)
                    #expect(piece.leading.allSatisfy(\.isWhitespace) && piece.trailing.allSatisfy(\.isWhitespace))
                }
            }
        }
    }

    @Test("empty and whitespace-only text is one piece with nothing to rewrite; text that fits is one piece")
    func shortTextIsOnePiece() throws {
        #expect(TextSplitter.pieces(of: "", maxBytes: 100) == [TextPiece(leading: "", body: "", trailing: "")])
        #expect(TextSplitter.pieces(of: " \n\t ", maxBytes: 100) == [TextPiece(leading: " \n\t ", body: "", trailing: "")])
        #expect(TextSplitter.pieces(of: "  Hello there.\n", maxBytes: 10_000) == [TextPiece(leading: "  ", body: "Hello there.", trailing: "\n")])
    }

    /// The first paragraph's own sentence end sits nearer the byte middle
    /// (48 of 105) than the paragraph break (90), and the break still wins.
    @Test("a paragraph break beats a sentence end nearer the middle")
    func paragraphBreakComesFirst() throws {
        let first = "First sentence of the opening paragraph is here. Second sentence of the opening paragraph."
        let second = "Closing line."
        let pieces = try #require(TextSplitter.pieces(of: first + "\n\n" + second, maxBytes: 95))

        #expect(pieces == [
            TextPiece(leading: "", body: first, trailing: "\n\n"),
            TextPiece(leading: "", body: second, trailing: ""),
        ])
    }

    /// Each trap sits nearer the halfway point than any real sentence end
    /// inside the window, so a boundary there would be the one chosen. Three
    /// are real `NLTokenizer` splits (measured 2026-10-08) with no space
    /// after them: "Q3." and "Report?" inside a link, ".." inside a relative
    /// path, all stopped by the whitespace rule; and "Oct." before "12.",
    /// stopped only by the digit check. The rest pin what `NLTokenizer`
    /// already gets right.
    @Test("no piece ends at an abbreviation, a decimal, inside a link, or before a number")
    func sentenceTrapsAreNotBoundaries() throws {
        let opening = "Sales rose in March and April across every region we track. "
        let closing = " The team will share the full breakdown on Thursday morning."
        let traps = [
            ("Dr.", "The cohort shift is real, says our analyst Dr. Patel, and it explains most of it."),
            ("e.g.", "Several segments moved together, e.g. new users on the annual plan in March too."),
            ("U.S.", "Most of the decline happened in the U.S. market during the second half of March."),
            ("3.", "Churn in the cohort rose by 3.5 points over the quarter, more than anyone expected."),
            ("Q3.", "The raw numbers live at https://example.com/Q3.Report?Region=EMEA for anyone who wants them."),
            ("Report?", "The raw numbers live at https://example.com/Q3.Report?Region=EMEA for anyone who wants them."),
            ("Oct.", "After a long debate the launch is set for Oct. 12. Everyone agreed."),
            ("..", "Before the review please open ../Reports.Q3/Overview and read it again."),
        ]
        for (trap, middle) in traps {
            let text = opening + middle + closing
            let pieces = try #require(TextSplitter.pieces(of: text, maxBytes: text.utf8.count * 2 / 3))
            #expect(pieces.count >= 2, "\(trap)")
            #expect(!pieces.contains { $0.body.hasSuffix(trap) }, "split at \(trap)")
            #expect(pieces.allSatisfy { $0.body.last.map { ".!?".contains($0) } == true }, "\(trap)")
        }
    }

    /// Casual writing is often all lowercase. `NLTokenizer` already declines
    /// to break before a lowercase word after a period, and the break it does
    /// make here is a real sentence end, so refusing it would cut the message
    /// mid-sentence instead.
    @Test("a sentence end before a lowercase word is still a sentence end")
    func lowercaseSentencesStillSplit() throws {
        let pieces = try #require(TextSplitter.pieces(
            of: "is this ok? yes it is. we can ship it tomorrow if the numbers hold up. let me know.",
            maxBytes: 75
        ))

        #expect(pieces == [
            TextPiece(leading: "", body: "is this ok?", trailing: " "),
            TextPiece(leading: "", body: "yes it is. we can ship it tomorrow if the numbers hold up. let me know.", trailing: ""),
        ])
    }

    @Test("Japanese splits at its own sentence ends")
    func japaneseSplitsAtSentenceEnds() throws {
        let pieces = try #require(TextSplitter.pieces(of: String(repeating: Self.japanese, count: 3), maxBytes: 120))

        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.body.last.map { "。！？".contains($0) } == true })

        // Quoted speech ends in a closing bracket after the full stop, with no
        // space before the next quote: still a sentence end, or a long quoted
        // passage has no boundary at all and the rewrite is refused.
        let quoted = try #require(TextSplitter.pieces(of: String(repeating: "「今日は晴れです。」", count: 200), maxBytes: 600))
        #expect(quoted.count >= 10)
        #expect(quoted.allSatisfy { $0.body.hasSuffix("。」") })

        // The same with plain ASCII quotes, which open and close alike: a quote
        // after an odd number of them closes, so it stays with its sentence.
        let ascii = try #require(TextSplitter.pieces(of: String(repeating: "\"今日は晴れです。\"", count: 200), maxBytes: 600))
        #expect(ascii.count >= 9)
        #expect(ascii.allSatisfy { $0.body.hasPrefix("\"") && $0.body.hasSuffix("。\"") })
    }

    /// A full stop in a URL's path reads as a sentence end to `NLTokenizer`
    /// and as the URL's end to link detection, and without a space nothing
    /// tells a link that goes on from a sentence that follows one. So the
    /// space-free stretch around a link stays whole when it fits a piece,
    /// like code; one longer than a piece may still be cut, not refused.
    @Test("a link and whatever is glued to it stay in one piece when they fit; longer ones can still be cut")
    func linksStayWhole() throws {
        for tail in ["。最新版/概要", "。最新版"] {
            let link = "https://example.com/" + String(repeating: "報告書", count: 20) + tail
            let text = "資料は " + link + " にあります。明日確認します。"
            let pieces = try #require(TextSplitter.pieces(of: text, maxBytes: text.utf8.count - 20), "\(tail)")
            #expect(!pieces.contains { $0.body.hasSuffix("報告書。") }, "\(tail)")
            #expect(pieces.contains { $0.body.contains(link) }, "\(tail)")
        }

        let glued = "https://example.com/" + String(repeating: "報告書", count: 20) + "。" + String(repeating: "明日確認します。", count: 8)
        let cut = try #require(TextSplitter.pieces(of: glued, maxBytes: glued.utf8.count / 2 + 30))
        #expect(cut.count >= 2)
        #expect(cut.allSatisfy { $0.body.hasSuffix("。") })
    }

    /// A limit of zero or less fits no text at all. Refused rather than
    /// divided by: the engine's own guard keeps it from happening, and a
    /// crash would take the whole app with it.
    @Test("a limit that fits nothing refuses the split")
    func nonPositiveLimitsRefuse() {
        #expect(TextSplitter.pieces(of: "fix this", maxBytes: 0) == nil)
        #expect(TextSplitter.pieces(of: "fix this", maxBytes: -10) == nil)
        #expect(TextSplitter.pieces(of: "fix this", maxBytes: 8) == [TextPiece(leading: "", body: "fix this", trailing: "")])
    }

    /// The only boundary in the window is the space after "hello", well short
    /// of the halfway point. Taking it beats cutting the long word in half.
    @Test("a word that fits is never cut; a word longer than a piece refuses the split")
    func wordsAreNeverCut() throws {
        let long = String(repeating: "x", count: 95)
        #expect(TextSplitter.pieces(of: "hello " + long, maxBytes: 100) == [
            TextPiece(leading: "", body: "hello", trailing: " "),
            TextPiece(leading: "", body: long, trailing: ""),
        ])
        #expect(TextSplitter.pieces(of: "hello " + String(repeating: "y", count: 150), maxBytes: 100) == nil)
        // A path is one word too, though `NLTokenizer` breaks it after "..".
        #expect(TextSplitter.pieces(of: "../Reports.Q3/Overview", maxBytes: 20) == nil)
    }

    /// The blank line inside the fence (byte 93) is nearer the halfway point
    /// (96) than the paragraph break before the fence (82), so without the
    /// protection the fence would be cut in two.
    @Test("a code block that fits stays in one piece; one that does not is split at its blank line")
    func codeBlocksStayWhole() throws {
        let fence = "```\na = 1\n\nb = 2 -- c\n```"
        let intro = String(repeating: "Intro text. ", count: 6) + "Intro end."
        let outro = String(repeating: "Outro text. ", count: 6) + "Outro end."
        #expect(intro.utf8.count == 82 && fence.utf8.count == 25)

        let pieces = try #require(TextSplitter.pieces(of: intro + "\n\n" + fence + "\n\n" + outro, maxBytes: 100))
        #expect(pieces.contains { $0.body == fence })
        #expect(!pieces.contains { $0.body.hasSuffix("a = 1") })

        #expect(TextSplitter.pieces(of: fence, maxBytes: 20) == [
            TextPiece(leading: "", body: "```\na = 1", trailing: "\n\n"),
            TextPiece(leading: "", body: "b = 2 -- c\n```", trailing: ""),
        ])
    }

    /// Six equal sentences, room for four in a piece: filling the first piece
    /// would leave 223 and 111 bytes; balancing leaves 167 and 167.
    @Test("pieces come out balanced, not one full piece and a short tail")
    func piecesAreBalanced() throws {
        let sentence = "This sentence is exactly the same length as the others."
        let text = Array(repeating: sentence, count: 6).joined(separator: " ")
        let pieces = try #require(TextSplitter.pieces(of: text, maxBytes: 250))

        #expect(pieces.map { $0.body.utf8.count } == [167, 167])
    }
}
