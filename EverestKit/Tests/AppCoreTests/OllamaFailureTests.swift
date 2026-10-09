import Engines
import Overlay
import RewriteCore
import Testing

@testable import AppCore

/// What the panel says when an Ollama rewrite fails.
@Suite("Ollama failures")
struct OllamaFailureTests {
    /// The engine's sentence, not the generic one: "pick a different model"
    /// is the wrong advice when Ollama is simply not running.
    @Test("an Ollama failure shows its own sentence, with the user's host")
    func ollamaFailuresKeepTheirWords() {
        let unreachable = OllamaError.unreachable(host: "10.0.0.5:11434")

        #expect(EngineFailure.reason(for: unreachable) == unreachable.message)
        #expect(EngineFailure.reason(for: unreachable).contains("10.0.0.5:11434"))
    }

    /// A piece of a long selection is checked as it finishes, so a refusal
    /// can arrive from the engine. It reads as the coordinator's own
    /// validation refusal does, and anything else stays an error.
    @Test("a refused piece reads like any refused rewrite; other failures stay errors")
    func refusedPiecesAreRefusals() {
        #expect(EngineFailure.state(for: ValidationFailure.empty) == .refused(reason: ValidationFailure.empty.message))
        #expect(EngineFailure.state(for: OllamaError.interrupted) == .error(reason: OllamaError.interrupted.message))
    }
}
