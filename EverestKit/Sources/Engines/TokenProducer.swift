import Foundation

/// What a decoder is allowed to do for one request.
public struct GenerationSettings: Sendable, Equatable {
    public var temperature: Float
    public var contextCap: Int
    public var maxOutputTokens: Int

    public init(temperature: Float, contextCap: Int, maxOutputTokens: Int) {
        self.temperature = temperature
        self.contextCap = contextCap
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Why a decoder stopped, as `mlx-swift-lm` reports it.
///
/// This exists because **the two endings are not interchangeable**. A model
/// that emitted its stop token has finished a rewrite; a model that ran out of
/// output budget has produced the first part of one, and the two are
/// indistinguishable from the text alone — a truncated rewrite is ordinary
/// prose that simply stops. Without this the half-rewrite was written over the
/// user's selection. See `EngineLimits.outputBudget`.
public enum GenerationStop: Sendable, Equatable {
    /// The model emitted a stop token: the rewrite is complete.
    case endOfText
    /// The decoder hit `maxOutputTokens` first. Whatever came back is a
    /// fragment and must never reach the user's document.
    case budgetExhausted
    /// The task was cancelled, or the stream was torn down early.
    case cancelled
}

/// One thing a decoder produced.
public enum TokenEvent: Sendable, Equatable {
    /// The text a token decoded to. A **delta**, not a snapshot.
    case delta(String)
    /// The decoder finished. Always the last event, and emitted exactly once.
    case stopped(GenerationStop)
}

/// The seam between `MLXEngine` and MLX itself.
///
/// Everything the engine decides — accumulating deltas into snapshots, sizing
/// the output budget, refusing a truncated rewrite, stopping on cancel — is
/// driven against a fake conformer. The real conformer wraps `ChatSession` and
/// is integration-only, because exercising it needs 2.3 GB of weights and a
/// Metal device.
public protocol TokenProducer: Sendable {
    /// Loads the weights in `directory`, throwing if they will not run.
    ///
    /// This is what proves a download. `looksComplete`-style file checks catch
    /// only the obvious half-download and cannot tell a truncated safetensors
    /// file or an unsupported architecture from a working model.
    func load(from directory: URL) async throws

    /// Token count of `prompt` under the model's real tokenizer, used to size
    /// the output budget.
    func inputTokenCount(for prompt: String) async throws -> Int

    /// Yields the text each decoded token expands to — **deltas**, not
    /// snapshots, which is the shape `ChatSession.streamDetails` produces —
    /// followed by exactly one `.stopped` carrying why decoding ended.
    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<TokenEvent, Error>
}

extension EngineLimits {
    /// The settings a prompt of `inputTokens` gets decoded under.
    public static func settings(forInputTokens inputTokens: Int) -> GenerationSettings {
        GenerationSettings(
            temperature: temperature,
            contextCap: contextCap,
            maxOutputTokens: outputBudget(inputTokens: inputTokens)
        )
    }
}
