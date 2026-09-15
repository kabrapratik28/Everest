import Engines
import Overlay

/// Turns an error thrown mid-generation into the state the panel ends on.
///
/// `AppleEngineError` and `GenerationError` get their own words, reused rather
/// than reworded: they were written where the conditions are known, and each
/// points at a different fix. `ModelFetchError` and `MLXProducerError` are both
/// "this should not have happened" — a malformed repository id, a missing pin,
/// generation attempted before a load — so a bespoke remedy for each would be
/// inventing advice, which is worse than one honest sentence.
public enum EngineFailure {
    /// The sentence alone, for surfaces that are not the panel — the Model
    /// tab's test box has no `PanelState` to put it in.
    public static func reason(for error: any Error) -> String {
        if let apple = error as? AppleEngineError { return apple.message }
        // The decoder ran out of output budget, which the generic sentence
        // handles badly: "try again" invites repeating an attempt that hits
        // the same ceiling on the same passage, and it never says the
        // document was left alone. `GenerationError` already carries both.
        if let incomplete = error as? GenerationError { return incomplete.message }
        // Recoverable, and the words have to say so. `MLXEngine` has already
        // cleared the readiness marker by the time it throws this, so the very
        // next attempt re-downloads instead of failing identically forever.
        // The generic sentence is wrong twice here: it suggests switching
        // models, which fixes nothing, and it gives no hint that letting the
        // download run again is the one useful action.
        if case ModelStoreError.readyMarkerWithoutWeights = error { return weightsMissing }
        return generic
    }

    private static let weightsMissing =
        "The model files are missing, so Everest cannot run it. Download it again from Settings ▸ Model."

    /// The same sentence, in the state the panel ends on.
    ///
    /// Derived from `reason(for:)` rather than looking the words up a second
    /// time. The two were independent and had already drifted:
    /// `readyMarkerWithoutWeights` had a specific remedy here and no branch
    /// there, and `state` is the *panel* — every hotkey press — so the one
    /// case with real advice was the case that almost never showed it.
    /// `GenerationError` arrived the same way and had to be added twice.
    /// One table means the next error cannot reach one surface only.
    ///
    /// All this decides is whether the model declined. Apple's content filter
    /// cannot be disabled and fires on ordinary prose — a paragraph about a
    /// death, routine political writing — so `.refused` is accurate there and
    /// nowhere else: a missing download, an exhausted budget or an ineligible
    /// device are the app failing, and saying "the model declined" sends the
    /// user to reword writing that was never the problem.
    public static func state(for error: any Error) -> PanelState {
        let words = reason(for: error)
        return (error as? AppleEngineError) == .guardrailRefusal
            ? .refused(reason: words)
            : .error(reason: words)
    }

    private static let generic =
        "The rewrite stopped before it finished. Try again, or pick a different model in Settings."
}
