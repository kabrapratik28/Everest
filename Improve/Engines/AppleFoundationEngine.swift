//  AppleFoundationEngine.swift
//  Everest
//
//  The zero-download engine, backed by Apple's on-device foundation model. See
//  AGENTS.md in this directory for why availability is re-checked on every
//  request and why a guardrail refusal gets its own message.

import Foundation
import OSLog
import RewriteCore

#if canImport(FoundationModels)
    import FoundationModels
#endif

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.apple"
)

/// Every way the Apple engine can fail, each with its own sentence.
///
/// These are deliberately not collapsed into one "generation failed". Four of
/// them have completely different fixes: turn on Apple Intelligence, wait for a
/// download, shorten the selection, switch engine. A single message would send
/// the user looking in the wrong place for three of the four.
public enum AppleEngineError: LocalizedError, Equatable {
    case frameworkMissing
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case guardrailRefusal
    case modelRefused
    case selectionTooLong
    case unsupportedLanguage
    case rateLimited
    case busy
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return "Apple Intelligence is not available in this version of macOS. Choose a local model in Settings ▸ Model."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Turn it on in System Settings ▸ Apple Intelligence & Siri, or choose a local model in Settings ▸ Model."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence. Choose a local model in Settings ▸ Model."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Try again in a few minutes, or choose a local model in Settings ▸ Model."
        case .guardrailRefusal:
            return "Apple's content filter refused to rewrite this text. Nothing was sent off your Mac. Switch to a local model in Settings ▸ Model to rewrite it."
        case .modelRefused:
            return "Apple's model declined to answer this request. Switch to a local model in Settings ▸ Model to rewrite it."
        case .selectionTooLong:
            return "This selection is too long for Apple Intelligence. Select less text, or switch to a local model in Settings ▸ Model."
        case .unsupportedLanguage:
            return "Apple Intelligence does not support this language yet. Choose a local model in Settings ▸ Model."
        case .rateLimited:
            return "Apple Intelligence is rate limiting requests right now. Wait a moment and try again."
        case .busy:
            return "A rewrite is already running. Wait for it to finish or cancel it."
        case .generationFailed(let detail):
            return "Apple Intelligence could not complete the rewrite. \(detail)"
        }
    }
}

#if canImport(FoundationModels)

    /// A `RewriteEngine` backed by `SystemLanguageModel.default`.
    ///
    /// On-device only. The engine never touches `PrivateCloudComputeLanguageModel`,
    /// because the whole promise of this app is that the selection does not leave
    /// the Mac, and Private Cloud Compute would send it to Apple's servers. That is
    /// a product constraint, not a performance one: do not "upgrade" this to the
    /// cloud model to get better output.
    public final class AppleFoundationEngine: RewriteEngine {

        public let id: EngineID = .apple
        private let transaction = TransactionBox()

        public init() {}

        // MARK: - RewriteEngine

        public func availability() async -> EngineAvailability {
            switch Self.currentError() {
            case nil:
                return .ready
            case .some(let error):
                return .unavailable(reason: error.errorDescription ?? "Unavailable.")
            }
        }

        /// Nothing to download and nothing to load: the system owns the weights.
        ///
        /// The availability check still runs, so picking this engine in Settings
        /// surfaces "Apple Intelligence is turned off" right away instead of at the
        /// first hotkey press.
        public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
            if let error = Self.currentError() { throw error }
            progress(1.0)
        }

        public func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await self.run(request, into: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                self.transaction.begin(task)
                continuation.onTermination = { termination in
                    if case .cancelled = termination { task.cancel() }
                }
            }
        }

        public func cancel() async {
            transaction.cancel()
        }

        // MARK: - Generation

        private func run(
            _ request: RewriteRequest,
            into continuation: AsyncThrowingStream<RewriteEvent, Error>.Continuation
        ) async throws {
            continuation.yield(.preparing(progress: nil))

            // Re-checked here, not cached from launch. Apple Intelligence can be
            // switched off in System Settings at any moment, and the model can be
            // evicted and re-downloaded by the system. An availability answer from
            // five minutes ago is a guess.
            if let error = Self.currentError() { throw error }
            continuation.yield(.preparing(progress: 1.0))

            let prompt = PromptBuilder.build(text: request.text, preset: request.preset)
            let options = GenerationOptions(
                temperature: Double(EngineLimits.temperature),
                maximumResponseTokens: EngineLimits.outputBudget(
                    inputTokens: EngineLimits.estimatedTokens(in: prompt))
            )

            // A session per rewrite, with no instructions of its own: the safety
            // frame is already inside `prompt` and must stay exactly as
            // `PromptBuilder` wrote it.
            let session = LanguageModelSession(model: .default)

            var latest = ""
            do {
                // Apple's stream is already cumulative, so each snapshot is
                // forwarded as-is. Accumulating it, the way `MLXEngine` has to,
                // would concatenate the whole output to itself on every token.
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    latest = snapshot.content
                    continuation.yield(.outputSnapshot(latest))
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                throw Self.map(error)
            }
            try Task.checkCancellation()

            log.info("rewrite generated, \(latest.count, privacy: .public) characters")
            continuation.yield(.finished(latest))
        }

        // MARK: - Availability

        /// `nil` when the system model is usable right now.
        private static func currentError() -> AppleEngineError? {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                // `UnavailableReason` is not frozen, so a future macOS can add a
                // case. Falling through to a generic message is better than
                // claiming one of the three above.
                return .generationFailed("The system model reported an unknown reason.")
            }
        }

        // MARK: - Error mapping

        private static func map(_ error: Error) -> AppleEngineError {
            // macOS 27 replaced `LanguageModelSession.GenerationError` with
            // `LanguageModelError`. Both are checked because the deployment target
            // is 26.0 and either can arrive at runtime.
            if #available(macOS 27.0, *), let modern = error as? LanguageModelError {
                return mapModern(modern)
            }
            if #available(macOS 27.0, *), let sessionError = error as? LanguageModelSession.Error {
                switch sessionError {
                case .concurrentRequests: return .busy
                default: return .generationFailed(sessionError.localizedDescription)
                }
            }
            if let legacy = mapLegacy(error) {
                return legacy
            }
            return .generationFailed(error.localizedDescription)
        }

        @available(macOS 27.0, *)
        private static func mapModern(_ error: LanguageModelError) -> AppleEngineError {
            switch error {
            case .guardrailViolation: return .guardrailRefusal
            case .refusal: return .modelRefused
            case .contextSizeExceeded: return .selectionTooLong
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited: return .rateLimited
            default: return .generationFailed(error.localizedDescription)
            }
        }

        /// `nil` when `error` is not one of the pre-27 generation errors.
        ///
        /// The cast and the switch both live inside a function deprecated at the
        /// same version the enum is. That is what keeps the build warning-free the
        /// day the deployment target moves to macOS 27, while a machine still on 26
        /// keeps getting the specific messages.
        @available(macOS, deprecated: 27.0)
        private static func mapLegacy(_ error: Error) -> AppleEngineError? {
            guard let error = error as? LanguageModelSession.GenerationError else { return nil }
            switch error {
            case .guardrailViolation: return .guardrailRefusal
            case .refusal: return .modelRefused
            case .exceededContextWindowSize: return .selectionTooLong
            case .assetsUnavailable: return .modelNotReady
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited: return .rateLimited
            case .concurrentRequests: return .busy
            default: return .generationFailed(error.localizedDescription)
            }
        }
    }

#else

    /// Built when the SDK has no `FoundationModels` at all.
    ///
    /// The type still exists so `ModelCatalog`, Settings and `RewriteCoordinator`
    /// compile and run unchanged. It simply reports itself unavailable, which is
    /// the same state the real engine reports when Apple Intelligence is off, so
    /// the UI needs no separate path for it.
    public final class AppleFoundationEngine: RewriteEngine {

        public let id: EngineID = .apple

        public init() {}

        public func availability() async -> EngineAvailability {
            .unavailable(reason: AppleEngineError.frameworkMissing.errorDescription ?? "Unavailable.")
        }

        public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
            throw AppleEngineError.frameworkMissing
        }

        public func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
            AsyncThrowingStream<RewriteEvent, Error> { continuation in
                continuation.finish(throwing: AppleEngineError.frameworkMissing)
            }
        }

        public func cancel() async {}
    }

#endif
