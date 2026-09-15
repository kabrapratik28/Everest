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

/// The seam between `MLXEngine` and MLX itself.
///
/// Everything the engine decides — accumulating deltas into snapshots, sizing
/// the output budget, stopping on cancel — is driven against a fake conformer.
/// The real conformer wraps `ChatSession` and is integration-only, because
/// exercising it needs 2.3 GB of weights and a Metal device.
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
    /// snapshots, which is the shape `ChatSession.streamResponse` produces.
    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error>
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
