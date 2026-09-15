import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.mlx"
)

/// The real `TokenProducer`: `LLMModelFactory` and `ChatSession`.
///
/// **Integration-only.** Exercising any of this needs 2.3 GB of weights and a
/// Metal device. It is kept to translation for that reason — the accumulation,
/// budgeting and cancellation logic all live in `MLXEngine`, on the tested
/// side of the `TokenProducer` seam.
public final class MLXTokenProducer: TokenProducer {
    private let loaded = LoadedModel()

    public init() {}

    /// Loads the weights, which is what proves a download.
    public func load(from directory: URL) async throws {
        _ = try await loaded.container(at: directory)
        log.info("model container loaded")
    }

    public func inputTokenCount(for prompt: String) async throws -> Int {
        let container = try await loaded.current()
        return await container.encode(prompt).count
    }

    /// Translates `Generation` onto `TokenEvent`. No decisions: whether a
    /// `.budgetExhausted` rewrite may be shown is `MLXEngine`'s call, on the
    /// tested side of this seam.
    ///
    /// `streamDetails`, not `streamResponse`. They differ only in that
    /// `streamResponse` maps every element through `\.chunk` and therefore
    /// **throws the completion info away** — including `stopReason`, the one
    /// thing that distinguishes a finished rewrite from one the token budget
    /// cut in half. `mlx-swift-lm` yields exactly one `.info` immediately
    /// before finishing the stream, on every path.
    public func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await loaded.current()

                    var parameters = GenerateParameters()
                    parameters.temperature = settings.temperature
                    parameters.maxTokens = settings.maxOutputTokens
                    parameters.maxKVSize = settings.contextCap

                    // Fresh per rewrite. `ChatSession` exists to carry history
                    // and a warm KV cache across turns; reusing one would keep
                    // the previous selection resident in memory, which root
                    // AGENTS.md §5 rules out.
                    let session = ChatSession(container, generateParameters: parameters)

                    // `streamResponse(to:)` with a bare String is ambiguous
                    // between two overloads that differ only in defaulted
                    // parameters. The array form resolves cleanly and also
                    // documents that the prompt is one user turn with no
                    // system message — the safety frame is already inside it
                    // and must reach the model exactly as written.
                    for try await generated in session.streamDetails(
                        to: [Chat.Message.user(prompt)]
                    ) {
                        switch generated {
                        case let .chunk(text):
                            continuation.yield(.delta(text))
                        case let .info(info):
                            continuation.yield(.stopped(Self.stop(from: info.stopReason)))
                        // No tools are passed, so this cannot arrive. Ignored
                        // rather than trapped: an unreachable branch is not
                        // worth a crash in a rewrite.
                        case .toolCall:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    // Type name only. Never the prompt, never the output.
                    log.error("generation failed: \(String(describing: type(of: error)))")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GenerateStopReason` onto ours, one case each.
    ///
    /// Not folded into the call site: `mlx-swift-lm` uses `.cancelled` as its
    /// fallback when it cannot tell why the iterator ended, so the mapping is
    /// the one place that fact is worth stating.
    private static func stop(from reason: GenerateStopReason) -> GenerationStop {
        switch reason {
        case .stop: .endOfText
        case .length: .budgetExhausted
        case .cancelled: .cancelled
        @unknown default: .cancelled
        }
    }
}

public enum MLXProducerError: Error, Equatable, Sendable {
    /// Generation was attempted before `load(from:)`. `MLXEngine.prepare`
    /// always loads first, so this means a caller skipped it.
    case modelNotLoaded
}

/// Holds the loaded model.
///
/// An actor, unlike `TransactionBox`, because loading is genuinely async and
/// two hotkey presses half a second apart must not start two loads of the
/// same 2.3 GB model.
private actor LoadedModel {
    private var container: ModelContainer?

    func current() throws -> ModelContainer {
        guard let container else { throw MLXProducerError.modelNotLoaded }
        return container
    }

    func container(at directory: URL) async throws -> ModelContainer {
        if let container { return container }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: TransformersTokenizerLoader()
        )
        container = loaded
        return loaded
    }
}

/// Supplies a tokenizer, which mlx-swift-lm 3.x no longer bundles.
///
/// `MLXHuggingFace` ships a `#huggingFaceTokenizerLoader()` macro that expands
/// to roughly this. It is written out by hand because a macro-using target
/// makes Xcode refuse to build until the person at the keyboard clicks through
/// a "trust this macro plugin" prompt, which is a bad first five minutes for a
/// fresh checkout.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizerBridge(wrapped: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Adapts `Tokenizers.Tokenizer` onto `MLXLMCommon.Tokenizer`. The two
/// protocols describe the same thing with different member names.
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    let wrapped: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        wrapped.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        wrapped.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { wrapped.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { wrapped.convertIdToToken(id) }

    var bosToken: String? { wrapped.bosToken }
    var eosToken: String? { wrapped.eosToken }
    var unknownToken: String? { wrapped.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try wrapped.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
