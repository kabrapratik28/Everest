import Foundation
import Synchronization

@testable import Engines

/// A failure a scripted producer can raise, so a test can assert on this exact
/// one rather than on "something threw".
enum ProducerFailure: Error, Equatable {
    /// Stands in for a truncated safetensors file, or an architecture this
    /// build of mlx-swift-lm has no entry for: the download completed and the
    /// model still will not run.
    case weightsUnloadable
}

/// A `TokenProducer` that yields scripted deltas, records what it was asked
/// for, and can be made slow enough to cancel partway.
///
/// This is the stand-in for MLX. Real inference needs a 2.3 GB model, a Metal
/// device and seconds of decode, none of which belong in a unit test — but
/// accumulation, cancellation and parameter plumbing are all this app's own
/// logic and are fully driveable here.
///
/// State is held in a `Mutex` rather than an `NSLock`: `NSLock.lock()` is
/// unavailable from an asynchronous context under Swift 6, and the recording
/// happens inside the producer's own `Task`.
final class ScriptedTokenProducer: TokenProducer {
    /// Deltas yielded in order, exactly as `ChatSession.streamDetails` would.
    let deltas: [String]

    /// Reported as the last event, the way MLX reports `stopReason`.
    ///
    /// Defaults to `.endOfText` so every test that is not about truncation
    /// scripts a model that finished its sentence, which is the ordinary case.
    /// **`nil` scripts a producer that reports nothing** — the shape a future
    /// `mlx-swift-lm` would have if it stopped yielding completion info.
    let stop: GenerationStop?

    /// Reported as the prompt's token count, for the output budget.
    let promptTokens: Int

    /// Pause before each delta. A nonzero value gives a test room to cancel
    /// while the stream is still running.
    let delayBetweenDeltas: Duration

    /// Thrown from `load(from:)`, standing in for weights that arrived intact
    /// enough to finish downloading and still will not load.
    let loadFailure: ProducerFailure?

    private struct Recorded: Sendable {
        var settings: GenerationSettings?
        var deltasYielded = 0
        var loadedFrom: URL?
    }
    private let recorded = Mutex(Recorded())

    init(
        deltas: [String],
        stop: GenerationStop? = .endOfText,
        promptTokens: Int = 100,
        delayBetweenDeltas: Duration = .zero,
        loadFailure: ProducerFailure? = nil
    ) {
        self.deltas = deltas
        self.stop = stop
        self.promptTokens = promptTokens
        self.delayBetweenDeltas = delayBetweenDeltas
        self.loadFailure = loadFailure
    }

    /// The directory the engine proved the model from, or `nil` if it never
    /// asked. `nil` is the interesting value: it says the engine trusted a
    /// readiness marker without checking the weights behind it.
    var loadedFrom: URL? {
        recorded.withLock { $0.loadedFrom }
    }

    func load(from directory: URL) async throws {
        if let loadFailure { throw loadFailure }
        recorded.withLock { $0.loadedFrom = directory }
    }

    /// What the engine actually handed the decoder.
    var settingsUsed: GenerationSettings? {
        recorded.withLock { $0.settings }
    }

    /// How many deltas were produced before the stream stopped. A `cancel()`
    /// that merely drops results instead of stopping consumption leaves this
    /// at the full count, which is the bug the cancellation test is for.
    var deltasYielded: Int {
        recorded.withLock { $0.deltasYielded }
    }

    func inputTokenCount(for prompt: String) async throws -> Int {
        promptTokens
    }

    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<TokenEvent, Error> {
        recorded.withLock { $0.settings = settings }

        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                for delta in deltas {
                    if delayBetweenDeltas != .zero {
                        try? await Task.sleep(for: delayBetweenDeltas)
                    }
                    guard !Task.isCancelled else {
                        // Cut short, so the scripted `stop` never arrives —
                        // MLX reports `.cancelled` here, and either way the
                        // engine's cancellation check is what ends it.
                        continuation.finish()
                        return
                    }
                    recorded.withLock { $0.deltasYielded += 1 }
                    continuation.yield(.delta(delta))
                }
                if let stop { continuation.yield(.stopped(stop)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
