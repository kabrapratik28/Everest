import Foundation
import RewriteCore

/// Rewrites with a model on the user's own Ollama server. Opt-in, never the
/// default, and holding no weights of ours.
public struct OllamaEngine: RewriteEngine {
    public let id: EngineID = .ollama
    let client: OllamaClient
    /// Server address and model name, read fresh for every rewrite, so an
    /// edit in Settings applies to the next press without rebuilding this.
    let settings: @Sendable () async -> (server: String, model: String)
    private let transactions = TransactionBox()

    /// Ollama's own default; used until `/api/ps` reports the loaded model's.
    static let defaultWindow = 4096
    /// Room for the chat template Ollama wraps the prompt in.
    static let templateReserve = 64

    public init(client: OllamaClient, settings: @escaping @Sendable () async -> (server: String, model: String)) {
        self.client = client
        self.settings = settings
    }

    public func availability() async -> EngineAvailability {
        await client.status(at: settings().server).availability
    }

    /// Nothing to download: the models are Ollama's.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    /// A sizing guess, not a guard: qwen3 measured 4.9 bytes per token in
    /// English and 5.1 in Japanese (2026-10-08), so a third overestimates
    /// both. Other tokenizers and dense code can run closer to one byte per
    /// token; then Ollama refuses the piece (`truncate: false`) and nothing
    /// is replaced, which is the guard.
    static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    public func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pieces(of: request) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    // The user cancelled; they need no telling.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Registered before `stream(_:)` returns, so `cancel()` on the
            // next line finds it. See `TransactionBox`.
            transactions.begin(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() async {
        transactions.cancel()
    }

    private func pieces(of request: RewriteRequest, emit: (RewriteEvent) -> Void) async throws {
        let (address, model) = await settings()
        guard let server = OllamaServer(address) else { throw OllamaError.invalidAddress }
        guard !model.isEmpty else { throw OllamaError.noModelChosen }

        // Every time, before anything is sent: the saved name may have
        // stopped being a local model on this server, or be one that runs on
        // ollama.com, and the user asked for their own models only.
        guard try await client.localModels(at: server).contains(model) else {
            throw OllamaError.modelUnavailable(name: model, host: server.displayHost)
        }
        try Task.checkCancellation()
        let window = try await client.contextWindow(for: model, at: server) ?? Self.defaultWindow
        try Task.checkCancellation()

        // A prompt of at most window / 2.4 leaves room beside it for an
        // answer 1.4 times as long (`EngineLimits.outputScale`). The note for
        // part 999 of 999 is the longest one a piece can carry.
        let overhead = Self.estimatedTokens(PromptBuilder.build(text: "", preset: request.preset, part: (999, 999))) + Self.templateReserve
        let bodyTokens = window * 5 / 12 - overhead
        guard bodyTokens >= EngineLimits.minimumOutputTokens else { throw OllamaError.contextTooSmall(window: window) }
        guard let pieces = TextSplitter.pieces(of: request.text, maxBytes: bodyTokens * 3) else { throw OllamaError.wordTooLong }

        var written = ""
        for (number, piece) in pieces.enumerated() {
            guard !piece.body.isEmpty else {
                written += piece.leading + piece.trailing
                continue
            }
            let prompt = PromptBuilder.build(
                text: piece.body,
                preset: request.preset,
                part: pieces.count > 1 ? (number + 1, pieces.count) : nil
            )
            let promptTokens = Self.estimatedTokens(prompt) + Self.templateReserve
            let scaled = Int((Double(promptTokens) * EngineLimits.outputScale).rounded())
            let numPredict = min(max(EngineLimits.minimumOutputTokens, scaled), window - promptTokens)
            try Task.checkCancellation()

            var raw = ""
            var reason: String?
            for try await event in client.chat(ChatRequest(model: model, prompt: prompt, numPredict: numPredict), at: server) {
                switch event {
                case let .text(text):
                    raw += text
                    emit(.outputSnapshot(written + piece.leading + raw))
                case let .done(stop):
                    reason = stop
                }
            }
            try Task.checkCancellation()
            switch reason {
            case "stop": break
            case "length": throw GenerationError.truncated
            default: throw OllamaError.interrupted
            }

            // Cleaning and refusals per piece, typography once on the joined
            // text (`OutputValidator.checked`). The body had no edge
            // whitespace, so any the model added is dropped and the user's
            // own goes back around it.
            let rewritten = try OutputValidator.checked(raw, source: piece.body).get()
            written += piece.leading + rewritten.trimmingCharacters(in: .whitespacesAndNewlines) + piece.trailing
            if pieces.count > 1 { emit(.outputSnapshot(written)) }
        }
        emit(.finished(written))
    }
}
