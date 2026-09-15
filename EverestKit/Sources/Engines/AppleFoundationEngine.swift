import Foundation
import RewriteCore

/// Rewrites using Apple's on-device model. No download, but guardrails that
/// cannot be disabled — see root `AGENTS.md` §4 for why it is not the default.
public struct AppleFoundationEngine: RewriteEngine {
    public let id: EngineID = .apple
    let system: any AppleSystemModel
    private let transactions = TransactionBox()

    public init(system: any AppleSystemModel) {
        self.system = system
    }

    /// Whether Apple's model can serve a rewrite **right now**.
    ///
    /// Read fresh every time, never cached from launch or from a previous
    /// request. Apple Intelligence is a toggle in System Settings, and the
    /// system can evict and re-download its model on its own schedule, so a
    /// user can turn it off between two hotkey presses. A cached answer is a
    /// guess whose failure mode is an opaque error at exactly the wrong
    /// moment; the check costs a property read.
    public func availability() async -> EngineAvailability {
        guard let blocking = AppleEngineError.blocking(for: system) else { return .ready }
        return .unavailable(reason: blocking.message)
    }

    /// Nothing to download: Apple's model is either on the system or it is
    /// not, and `availability()` is what reports which.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    /// Streams a rewrite, forwarding Apple's snapshots unchanged.
    ///
    /// Do **not** accumulate here. Apple's values are already cumulative, so
    /// adding the accumulation `MLXEngine` does would concatenate the whole
    /// output to itself on every token.
    public func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Re-read availability here, not at launch. See above.
                    if let blocking = AppleEngineError.blocking(for: system) {
                        throw blocking
                    }

                    let prompt = PromptBuilder.build(text: request.text, preset: request.preset)
                    let settings = EngineLimits.settings(
                        forInputTokens: Self.estimatedTokens(in: prompt)
                    )

                    var latest = ""
                    for try await snapshot in system.stream(prompt: prompt, settings: settings) {
                        latest = snapshot
                        continuation.yield(.outputSnapshot(snapshot))
                    }

                    try Task.checkCancellation()

                    // `FoundationModels` reports neither a stop reason nor a
                    // token count, so unlike `MLXEngine` there is no exact
                    // signal to refuse on and the text is all there is. A
                    // rewrite Apple's model cut short is otherwise
                    // indistinguishable from a finished one, and
                    // `OutputValidator` has no lower bound to catch it.
                    if OutputCompleteness.looksTruncated(latest, source: request.text) {
                        throw GenerationError.truncated
                    }

                    continuation.yield(.finished(latest))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let incomplete as GenerationError {
                    // Ahead of `map`, whose default branch would reduce this
                    // to `.generationFailed("GenerationError")` — a sentence
                    // that blames Apple's model for stopping and offers the
                    // local model as the remedy. Neither is true here.
                    continuation.finish(throwing: incomplete)
                } catch {
                    // Classify before it leaves the engine. A raw
                    // `AppleSystemFailure` reaching the panel is a type the
                    // user cannot act on.
                    continuation.finish(throwing: AppleEngineError.map(error))
                }
            }
            transactions.begin(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the in-flight rewrite. No further events are emitted.
    public func cancel() async {
        transactions.cancel()
    }

    /// Four characters per token.
    ///
    /// Unlike `MLXEngine`, this engine has no reachable tokenizer —
    /// `FoundationModels` does not expose one — and this number only has to
    /// be close enough to size an output budget.
    static func estimatedTokens(in prompt: String) -> Int {
        max(1, prompt.count / 4)
    }
}
