import Foundation

/// Whether Apple's on-device model can serve a request right now.
///
/// These are the states `SystemLanguageModel.default.availability` reduces to.
/// They are kept as this app's own type so the engine's decision logic can be
/// driven in a test without a machine that has Apple Intelligence switched off.
public enum AppleSystemStatus: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady

    /// The OS is older than `FoundationModels`, so there is no framework to
    /// ask. Everest deploys to macOS 14 and Apple's model arrived in 26, so
    /// this is the state on most of the supported range. Deliberately not
    /// folded into `deviceNotEligible`: that sentence blames the hardware,
    /// and an M3 on macOS 15 is perfectly eligible once it updates.
    case requiresNewerOS
}

/// What a request to Apple's model can fail with once it has started.
///
/// The real adapter translates `LanguageModelError` (macOS 27) and the
/// deprecated `LanguageModelSession.GenerationError` (macOS 26) into these.
public enum AppleSystemFailure: Error, Equatable, Sendable {
    case guardrailRefusal
    case contextExceeded
    case generationFailed(String)
}

/// The seam between `AppleFoundationEngine` and `FoundationModels`.
///
/// Everything the engine decides — which error a user sees, whether a request
/// may start at all — is driven against a stub conformer. The real conformer
/// is integration-verified only, because Apple Intelligence state is a system
/// setting a test cannot set.
public protocol AppleSystemModel: Sendable {
    /// Read fresh on every request, never cached from launch.
    func currentStatus() -> AppleSystemStatus

    /// Yields **snapshots**, not deltas. Apple's `streamResponse` already
    /// carries the whole partial response at every step, which is why
    /// `RewriteEvent` is snapshot-shaped in the first place.
    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error>
}

/// A failure the user can act on.
public enum AppleEngineError: Error, Equatable, Sendable {
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case guardrailRefusal
    case contextExceeded
    case generationFailed(String)
    case requiresNewerOS

    /// One sentence per case, and each one points at a different fix.
    ///
    /// Resist folding these into "generation failed". The five conditions have
    /// five different remedies, so a single generic message sends the user
    /// looking in the wrong place four times out of five.
    ///
    /// The guardrail case earns its wording specifically. Apple's content
    /// filter cannot be disabled and it fires on ordinary prose — a paragraph
    /// about a death, routine political writing. Without being told it was a
    /// content filter, the user is staring at their own sentence unable to
    /// tell whether the app broke, the model broke, or their writing tripped
    /// something. Saying so, and saying nothing left the Mac, turns a dead end
    /// into one click.
    public var message: String {
        switch self {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Turn it on in System Settings, or switch Everest to the local model."
        case .deviceNotEligible:
            "This Mac is not eligible for Apple Intelligence. Switch Everest to the local model to rewrite text here."
        case .requiresNewerOS:
            "Apple's model needs macOS 26 or later. Update macOS to use it, or keep using Everest's own local model, which works here."
        case .modelNotReady:
            "Apple is still downloading its language model. Try again shortly, or switch Everest to the local model."
        case .guardrailRefusal:
            "Apple's content filter refused this text. Nothing left your Mac. The local model has no such filter."
        case .contextExceeded:
            "That selection is too long for Apple's model. Select a shorter passage and try again."
        case .generationFailed(let detail):
            "Apple's model stopped before it finished (\(detail)). Try again, or switch Everest to the local model."
        }
    }

    /// The error a request should fail with before it starts, or `nil` when
    /// the system can serve it.
    ///
    /// Takes the model rather than a status so that the freshness of the read
    /// is this function's responsibility and not the caller's to remember.
    public static func blocking(for model: any AppleSystemModel) -> AppleEngineError? {
        switch model.currentStatus() {
        case .available: nil
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .deviceNotEligible: .deviceNotEligible
        case .modelNotReady: .modelNotReady
        case .requiresNewerOS: .requiresNewerOS
        }
    }

    /// Classifies a failure thrown once generation is under way.
    ///
    /// The `default` branch carries a type name, never the error's
    /// description: a `FoundationModels` error can quote the offending
    /// prompt, and this string reaches both the panel and `OSLog`.
    public static func map(_ error: Error) -> AppleEngineError {
        switch error {
        case let failure as AppleSystemFailure:
            switch failure {
            case .guardrailRefusal: .guardrailRefusal
            case .contextExceeded: .contextExceeded
            case .generationFailed(let detail): .generationFailed(detail)
            }
        case let mapped as AppleEngineError:
            mapped
        default:
            .generationFailed(String(describing: type(of: error)))
        }
    }
}
