//  MLXEngine.swift
//  Everest
//
//  Local inference through mlx-swift-lm. See AGENTS.md in this directory for the
//  verified API surface and for why the deltas MLX produces are turned into
//  cumulative snapshots here rather than anywhere downstream.

import Foundation
import MLXLLM
import MLXLMCommon
import OSLog
import RewriteCore
import Tokenizers

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.mlx"
)

/// Generation limits shared by every engine.
///
/// These live here rather than in `RewriteCore` because they describe what the
/// decoder is allowed to do, not what a rewrite means. `AppleFoundationEngine`
/// reads the same numbers so the two engines cannot drift apart.
enum EngineLimits {
    static let temperature: Float = 0.2
    static let contextTokenCap = 8192
    static let minimumOutputTokens = 64
    static let maximumOutputTokens = 768
    static let inputToOutputRatio = 1.4

    /// A rewrite is roughly the length of its input, so the budget tracks the
    /// input with headroom. The floor keeps one-line selections from being cut
    /// off; the ceiling keeps a runaway generation from holding the panel open.
    static func outputBudget(inputTokens: Int) -> Int {
        let scaled = Int((Double(inputTokens) * inputToOutputRatio).rounded())
        return min(max(minimumOutputTokens, scaled), maximumOutputTokens)
    }

    /// Only used where no real tokenizer is reachable. Four characters per token
    /// is the usual English approximation and it only has to be close enough to
    /// size a budget.
    static func estimatedTokens(in text: String) -> Int {
        max(1, text.count / 4)
    }
}

public enum MLXEngineError: LocalizedError {
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            return "The model could not be loaded. \(reason)"
        }
    }
}

/// A `RewriteEngine` backed by a quantized MLX model running on the local GPU.
public final class MLXEngine: RewriteEngine {

    public let id: EngineID
    private let spec: ModelSpec
    private let store: Store
    private let transaction = TransactionBox()

    public init(spec: ModelSpec) {
        self.id = spec.id
        self.spec = spec
        self.store = Store()
    }

    // MARK: - RewriteEngine

    public func availability() async -> EngineAvailability {
        if await store.isLoaded { return .ready }
        if ModelDownloader.shared.isReady(spec.repoID) { return .ready }
        return .needsDownload(bytes: spec.approxBytes)
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await loadContainer(progress: progress)
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

            // Registered synchronously, before this initializer returns, so a
            // caller that calls cancel() on the very next line cannot miss it.
            self.transaction.begin(task)

            // Covers the caller that simply stops iterating instead of calling
            // cancel(). Without this the decoder keeps burning GPU time for a
            // panel nobody is looking at.
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

        // Downloading and loading together are one "preparing" phase to the user,
        // so the download is scaled into the first 95% and the load owns the rest.
        // A bar that sits at 100% through a twenty second load looks hung.
        //
        // Cancelling here stops the rewrite, not the download. The bytes already
        // on disk are worth keeping, and a shared load may belong to a Settings
        // download this hotkey press knows nothing about.
        let container = try await loadContainer { fraction in
            continuation.yield(.preparing(progress: fraction * 0.95))
        }
        try Task.checkCancellation()
        continuation.yield(.preparing(progress: 1.0))

        let prompt = PromptBuilder.build(text: request.text, preset: request.preset)
        // The budget tracks the selection, not the prompt: the safety frame is a
        // fixed overhead that says nothing about how long the rewrite should be.
        let inputTokens = await container.encode(request.text).count
        let parameters = GenerateParameters(
            maxTokens: EngineLimits.outputBudget(inputTokens: inputTokens),
            maxKVSize: EngineLimits.contextTokenCap,
            temperature: EngineLimits.temperature
        )

        // A fresh session per rewrite. `ChatSession` exists to carry conversation
        // history and a warm KV cache across turns, and carrying either one here
        // would mean the previous selection stays resident in memory, which §5 of
        // the root AGENTS.md rules out.
        let session = ChatSession(container, generateParameters: parameters)

        // MLX yields the text each token decoded to, not the text so far. Every
        // consumer in this app is snapshot-based, so the accumulation happens
        // once, here.
        var accumulated = ""
        for try await delta in session.streamResponse(to: [Chat.Message.user(prompt)]) {
            try Task.checkCancellation()
            accumulated += delta
            continuation.yield(.outputSnapshot(accumulated))
        }
        try Task.checkCancellation()

        log.info("rewrite generated, \(accumulated.count, privacy: .public) characters")
        continuation.yield(.finished(accumulated))
    }

    // MARK: - Loading

    private func loadContainer(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        let spec = self.spec
        return try await store.container {
            try await Self.performLoad(spec: spec, progress: progress)
        }
    }

    private static func performLoad(
        spec: ModelSpec,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        let repoID = spec.repoID
        let downloader = ModelDownloader.shared

        let directory: URL
        if let existing = downloader.snapshotURL(for: repoID), downloader.isReady(repoID) {
            progress(1.0)
            directory = existing
        } else {
            directory = try await downloader.download(repoID: repoID, progress: progress)
        }
        try Task.checkCancellation()

        // Start from the registry entry when the repository has one so any
        // model-specific stop tokens or chat conventions come along, then point it
        // at the copy already on disk so the factory's own downloader never runs.
        var configuration = LLMModelFactory.shared.configuration(id: repoID)
        configuration.id = .directory(directory)
        if configuration.extraEOSTokens.isEmpty {
            // Every model in `ModelCatalog` is a Qwen ChatML checkpoint. The id is
            // also read from config.json, so this is a second line of defence
            // against a checkpoint that ships an incomplete generation config and
            // would otherwise never stop.
            configuration.extraEOSTokens = ["<|im_end|>"]
        }

        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: UnreachableDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: configuration)
        } catch {
            // The download can complete and still produce a model that will not
            // load: a truncated safetensors file, a config this build of
            // mlx-swift-lm has no architecture for. Leaving it unmarked means the
            // next launch offers to download it again rather than failing the same
            // way forever.
            log.error("model load failed: \(String(describing: type(of: error)), privacy: .public)")
            throw MLXEngineError.loadFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        await downloader.markReady(repoID)
        progress(1.0)
        log.info("model loaded")
        return container
    }

    // MARK: - State

    /// Holds the loaded model and dedupes the load.
    ///
    /// An actor rather than a lock because loading is async: two hotkey presses
    /// half a second apart, or a hotkey press during a Settings download, must
    /// join one load of a 2.3 GB model rather than starting two.
    private actor Store {
        private var loaded: ModelContainer?
        private var loading: Task<ModelContainer, Error>?

        var isLoaded: Bool { loaded != nil }

        func container(
            orLoad load: @escaping @Sendable () async throws -> ModelContainer
        ) async throws -> ModelContainer {
            if let loaded { return loaded }
            if let loading { return try await loading.value }

            // Unstructured on purpose: a caller that gives up must not take the
            // load down with it, because the other callers awaiting this same
            // task still want it.
            let task = Task { try await load() }
            loading = task
            defer { loading = nil }

            let container = try await task.value
            loaded = container
            return container
        }
    }
}

/// The one in-flight generation, guarded by a lock rather than an actor.
///
/// `stream(_:)` is synchronous, so registering the task has to be synchronous
/// too. Hopping to an actor to record it opens a window where `cancel()` runs
/// first, finds nothing, and leaves a generation running with nobody reading it.
final class TransactionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Task<Void, Never>?

    func begin(_ task: Task<Void, Never>) {
        lock.lock()
        let previous = current
        current = task
        lock.unlock()
        // Pressing the hotkey again replaces the transaction, so the one it
        // replaced stops decoding rather than racing it to the same selection.
        previous?.cancel()
    }

    func cancel() {
        lock.lock()
        let task = current
        current = nil
        lock.unlock()
        task?.cancel()
    }
}

// MARK: - Downloader and tokenizer adapters

/// A `Downloader` that must never be called.
///
/// `MLXEngine` always hands the factory a `ModelConfiguration` whose id is a
/// local `.directory`, and `MLXLMCommon.resolve` only reaches for the downloader
/// on the `.id` branch. Passing this instead of a real Hugging Face client keeps
/// every byte that reaches disk under `ModelDownloader`'s control, so nothing can
/// quietly populate the shared `~/.cache/huggingface` behind the user's back.
private struct UnreachableDownloader: MLXLMCommon.Downloader {
    struct Unexpected: LocalizedError {
        let id: String
        var errorDescription: String? {
            "Internal error: the model factory tried to download \(id) itself."
        }
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw Unexpected(id: id)
    }
}

/// Adapts `swift-transformers` to `MLXLMCommon.Tokenizer`.
///
/// This is the hand-written equivalent of mlx-swift-lm's
/// `#huggingFaceTokenizerLoader()` macro. Written out rather than expanded
/// because an Xcode build of a macro-using target needs the user to trust and
/// enable the macro plugin before it will compile, and that is a terrible first
/// experience for a checkout.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers spells this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
