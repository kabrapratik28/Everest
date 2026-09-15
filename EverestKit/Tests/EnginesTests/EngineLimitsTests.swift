import Testing

@testable import Engines

@Suite("EngineLimits")
struct EngineLimitsTests {
    /// The budget is `min(max(64, inputTokens * 1.4), 768)`, measured at the
    /// floor clamp, the linear middle, and the ceiling clamp.
    ///
    /// The middle point is load-bearing beyond "1.4 works". `1.4` has no exact
    /// binary representation, so `200 * 1.4` is `279.999...` and a truncating
    /// `Int(...)` conversion yields 279, not 280. Asserting 280 forces the
    /// implementation to round rather than truncate, which is the difference
    /// between the documented formula and an off-by-one on every rewrite.
    @Test("output budget clamps to 64 and 768 and scales by 1.4 in between")
    func outputBudgetAtBothClampsAndBetween() {
        #expect(EngineLimits.outputBudget(inputTokens: 10) == 64)
        #expect(EngineLimits.outputBudget(inputTokens: 200) == 280)
        #expect(EngineLimits.outputBudget(inputTokens: 2000) == 768)
    }
}
