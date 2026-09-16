import Foundation
import os

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.apple"
)

#if canImport(FoundationModels)

    import FoundationModels

    /// The real `AppleSystemModel`: translation onto `FoundationModels`.
    ///
    /// **Integration-only.** Every branch here depends on machine state a test
    /// cannot set — whether Apple Intelligence is switched on, whether this Mac
    /// is eligible, whether the system has finished downloading its model. The
    /// decisions those states feed are all on the other side of the seam, in
    /// `AppleEngineError` and `AppleFoundationEngine`.
    @available(macOS 26, *)
    public struct SystemLanguageModelAdapter: AppleSystemModel {
        public init() {}

        /// Read fresh on every call. Never cache this.
        ///
        /// **`SystemLanguageModel.default` only, never
        /// `PrivateCloudComputeLanguageModel`.** The macOS 27 SDK puts that
        /// type right next to this one with a nearly identical `availability`
        /// surface, and it would produce better output. It also sends the
        /// selected text to Apple's servers, which breaks the only promise
        /// this app makes. Product constraint, not a performance tradeoff.
        public func currentStatus() -> AppleSystemStatus {
            switch SystemLanguageModel.default.availability {
            case .available:
                .available
            case .unavailable(.appleIntelligenceNotEnabled):
                .appleIntelligenceNotEnabled
            case .unavailable(.deviceNotEligible):
                .deviceNotEligible
            case .unavailable(.modelNotReady):
                .modelNotReady
            case .unavailable:
                // A reason added in a later OS. Treat as not-ready rather
                // than claiming availability we cannot vouch for.
                .modelNotReady
            }
        }

        public func stream(
            prompt: String,
            settings: GenerationSettings
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // No `instructions:`. The safety frame is already
                        // inside `prompt` and must reach the model exactly as
                        // `PromptBuilder` wrote it; lifting part of it into a
                        // system prompt would change what the model sees.
                        let session = LanguageModelSession(instructions: nil)
                        let options = GenerationOptions(
                            temperature: Double(settings.temperature),
                            maximumResponseTokens: settings.maxOutputTokens
                        )

                        // Apple's snapshots are already cumulative. Forward
                        // them; `AppleFoundationEngine` does not accumulate.
                        for try await snapshot in session.streamResponse(
                            to: prompt,
                            options: options
                        ) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.classify(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Reduces both Apple error families to the seam's vocabulary.
        ///
        /// Two families have to be handled. `LanguageModelSession.GenerationError`
        /// is what a macOS 26 machine throws; macOS 27 deprecated it in favour
        /// of `LanguageModelError` with renamed cases
        /// (`exceededContextWindowSize` became `contextSizeExceeded`). The
        /// deployment target is 26.0 and the SDK is 27.0, so either can arrive
        /// at runtime.
        static func classify(_ error: Error) -> AppleSystemFailure {
            if #available(macOS 27.0, *), let modern = error as? LanguageModelError {
                switch modern {
                case .contextSizeExceeded:
                    return .contextExceeded
                case .guardrailViolation:
                    return .guardrailRefusal
                case .refusal:
                    // The model declining, not the safety layer intercepting.
                    // Different systems; kept distinguishable in the message.
                    return .generationFailed("the model declined this text")
                default:
                    return .generationFailed(String(describing: type(of: error)))
                }
            }
            return classifyLegacy(error)
        }

        /// The cast and the switch stay inside one function annotated
        /// deprecated, which is what keeps the build warning-free on the day
        /// the deployment target moves to 27.
        @available(macOS, deprecated: 27.0)
        private static func classifyLegacy(_ error: Error) -> AppleSystemFailure {
            guard let legacy = error as? LanguageModelSession.GenerationError else {
                return .generationFailed(String(describing: type(of: error)))
            }
            switch legacy {
            case .exceededContextWindowSize:
                return .contextExceeded
            case .guardrailViolation:
                return .guardrailRefusal
            default:
                return .generationFailed(String(describing: type(of: error)))
            }
        }
    }

#endif

/// What `.apple` resolves to when `FoundationModels` cannot be reached,
/// which is the ordinary case across most of the supported range: Everest
/// deploys to macOS 14 and Apple's model arrived in 26.
///
/// Two different conditions land here and the user cannot act differently on
/// either, so they share one answer: the running system is older than 26, or
/// the SDK this was built against has no `FoundationModels` at all.
///
/// It reports `.requiresNewerOS` rather than `.deviceNotEligible`, which is
/// what the old build-time stub said. That sentence blames the hardware, and
/// an M3 on macOS 15 is perfectly eligible the moment it updates.
public struct UnsupportedOSSystemModel: AppleSystemModel {
    public init() {}

    public func currentStatus() -> AppleSystemStatus { .requiresNewerOS }

    /// Unreachable in practice: `availability()` and `stream` both consult
    /// `blocking(for:)` first and refuse. Throwing the same cause rather than
    /// finishing empty keeps it that way if a future caller forgets.
    public func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AppleSystemFailure.generationFailed("requiresNewerOS")) }
    }
}
