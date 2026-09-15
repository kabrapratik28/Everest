import Testing

@testable import Engines

/// The backstop for an engine that cannot say why it stopped.
///
/// `MLXEngine` refuses on `GenerateStopReason.length`, which is exact.
/// `AppleFoundationEngine` has no equivalent — `FoundationModels` exposes no
/// stop reason and no token count — so truncation there has to be inferred
/// from the text, and this is the inference.
///
/// **Deliberately not a length ratio.** The obvious lower bound, "reject
/// output much shorter than its source", rejects honest work: `Concise` is a
/// built-in style whose instruction is *"Make this significantly shorter and
/// more direct"*, and a good concise rewrite is routinely 40% of the original
/// — the same proportion a truncation produces. A ratio cannot tell those
/// apart, because the difference between them is not how much text came back.
/// It is **where the text stops**.
@Suite("OutputCompleteness")
struct OutputCompletenessTests {
    /// A complete sentence in, a fragment out, is the signature of a decoder
    /// that ran out of budget mid-word.
    @Test("output that stops mid-sentence, where the source did not, is truncated")
    func aFragmentFromACompleteSourceIsTruncated() {
        #expect(
            OutputCompleteness.looksTruncated(
                "The quarterly report is ready for your rev",
                source: "the quarterly report is ready for you to review it now."
            )
        )
    }

    /// The whole reason for choosing this rule over a ratio, asserted so the
    /// ratio cannot come back. This output is 38% of its source and correct.
    @Test("a much shorter rewrite that ends properly is not truncated")
    func anHonestConciseRewriteIsNotTruncated() {
        #expect(
            OutputCompleteness.looksTruncated(
                "The report is ready for review.",
                source:
                    "I was just writing to let you know that the quarterly report is now ready "
                    + "and available for you to review whenever you get a chance to look at it."
            ) == false
        )
    }

    /// Fails open. A source that is not a complete sentence — a heading, a
    /// list item, a code span, the practice text in onboarding — gives the
    /// rule nothing to compare against, and guessing there would refuse
    /// correct rewrites of every fragment the user ever selects.
    @Test("a source that is itself a fragment never triggers the rule")
    func aFragmentSourceNeverTriggersTheRule() {
        #expect(
            OutputCompleteness.looksTruncated(
                "we were hoping to get your thoughts this week",
                source: "we was hoping to get your thoughts sometime this week"
            ) == false
        )
    }

    /// Trailing whitespace and closing delimiters are not the end of the
    /// sentence, on either side. Without this the rule fires on a rewrite that
    /// correctly closes a quotation, and misses a source whose full stop is
    /// followed by a newline.
    @Test("closing quotes, brackets and trailing whitespace are looked through")
    func closingDelimitersAndWhitespaceAreIgnored() {
        #expect(
            OutputCompleteness.looksTruncated(
                "She said, \"the report is ready.\"\n",
                source: "she said \"the report is ready\".  \n"
            ) == false
        )
        #expect(
            OutputCompleteness.looksTruncated(
                "She said, \"the report is ready for your rev",
                source: "she said \"the report is ready for you to review\".  \n"
            )
        )
    }

    /// Empty output is `OutputValidator`'s `.empty`, not this rule's business.
    /// Claiming it here would give one failure two names.
    @Test("empty output is not this rule's concern")
    func emptyOutputIsNotThisRulesConcern() {
        #expect(OutputCompleteness.looksTruncated("", source: "A complete sentence.") == false)
    }
}
