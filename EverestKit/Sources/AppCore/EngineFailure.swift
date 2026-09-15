import Engines
import Overlay

/// Turns an error thrown mid-generation into the state the panel ends on.
///
/// Only `AppleEngineError` gets its own words, and they are reused rather than
/// reworded: those six sentences each point at a different fix and were
/// written where the conditions are known. `ModelFetchError` and
/// `MLXProducerError` are both "this should not have happened" — a malformed
/// repository id, a missing pin, generation attempted before a load — so
/// writing a bespoke remedy for each would be inventing advice, which is worse
/// than one honest sentence.
public enum EngineFailure {
    /// The sentence alone, for surfaces that are not the panel — the Model
    /// tab's test box has no `PanelState` to put it in.
    public static func reason(for error: any Error) -> String {
        if let apple = error as? AppleEngineError { return apple.message }
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
