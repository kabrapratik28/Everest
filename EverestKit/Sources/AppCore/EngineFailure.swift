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

    public static func state(for error: any Error) -> PanelState {
        // `.error`, not `.refused`: the model did not decline, it ran out of
        // room. Blaming it for an arithmetic limit this app set would send
        // the user looking for a better model instead of a shorter passage.
        if let incomplete = error as? GenerationError {
            return .error(reason: incomplete.message)
        }
        guard let apple = error as? AppleEngineError else {
            return .error(reason: generic)
        }
        // Apple's content filter cannot be disabled and fires on ordinary
        // prose — a paragraph about a death, routine political writing. That
        // is the model declining, not the app breaking, and `refused` is the
        // state that says so. Reporting it as a failure sends the user looking
        // for a bug in Everest.
        return apple == .guardrailRefusal
            ? .refused(reason: apple.message)
            : .error(reason: apple.message)
    }

    private static let generic =
        "The rewrite stopped before it finished. Try again, or pick a different model in Settings."
}
