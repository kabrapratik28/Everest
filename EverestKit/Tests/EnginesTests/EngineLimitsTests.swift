import Testing

@testable import Engines

@Suite("EngineLimits")
struct EngineLimitsTests {
    /// The budget is `min(max(64, inputTokens * 1.4), contextCap - inputTokens)`,
    /// measured at the floor clamp and in the linear middle.
    ///
    /// The middle point is load-bearing beyond "1.4 works". `1.4` has no exact
    /// binary representation, so `200 * 1.4` is `279.999...` and a truncating
    /// `Int(...)` conversion yields 279, not 280. Asserting 280 forces the
    /// implementation to round rather than truncate, which is the difference
    /// between the documented formula and an off-by-one on every rewrite.
    @Test("output budget floors at 64 and scales by 1.4 above it")
    func outputBudgetAtTheFloorAndInTheLinearRange() {
        #expect(EngineLimits.outputBudget(inputTokens: 10) == 64)
        #expect(EngineLimits.outputBudget(inputTokens: 200) == 280)
        #expect(EngineLimits.outputBudget(inputTokens: 2000) == 2800)
    }

    /// **The budget must be able to hold a rewrite of its own input.**
    ///
    /// This is the invariant a fixed ceiling broke. A rewrite is "the same
    /// sentence, better", so its length tracks the input's; a budget smaller
    /// than the input cannot hold one, the decoder stops at `maxTokens`
    /// mid-word, and nothing downstream can tell that half-rewrite from a
    /// finished one — `OutputValidator` only rejects output that is *too
    /// long*. The old `maximumOutputTokens = 768` violated this from about 550
    /// input tokens upward, which is a selection of roughly 2,200 characters,
    /// while `TextBridge` captures up to 8,000.
    ///
    /// Asserted as a property over the range rather than at one point, because
    /// the defect was two constants that each looked reasonable alone. A
    /// single sample is satisfied by any ceiling above it and would let the
    /// same drift back in.
    ///
    /// The range stops at `contextCap / 2` because that is where the invariant
    /// genuinely stops being satisfiable: past it the input and a rewrite of
    /// the same length cannot both fit in the KV cache. Those selections are
    /// refused by the stop-reason check in `MLXEngine` rather than truncated.
    @Test("the budget can hold a rewrite as long as its input, within the context cap")
    func budgetCanAlwaysHoldARewriteOfItsInput() {
        for inputTokens in [64, 200, 549, 1_000, 2_000, 3_000, EngineLimits.contextCap / 2] {
            let budget = EngineLimits.outputBudget(inputTokens: inputTokens)

            #expect(
                budget >= inputTokens,
                "\(inputTokens) input tokens got a \(budget)-token budget: a rewrite would be cut off"
            )
            #expect(
                inputTokens + budget <= EngineLimits.contextCap,
                "\(inputTokens) + \(budget) overruns the \(EngineLimits.contextCap)-token KV cache"
            )
        }
    }
}
