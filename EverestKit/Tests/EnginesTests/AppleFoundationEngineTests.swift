import Foundation
import RewriteCore
import os
import Testing

@testable import Engines

/// An `AppleSystemModel` that counts how often it was read and can change its
/// answer between reads — which is exactly what a user toggling Apple
/// Intelligence in System Settings looks like to this app.
final class CountingAppleSystemModel: AppleSystemModel {
    private struct State: Sendable {
        var status: AppleSystemStatus
        var reads = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(status: AppleSystemStatus) {
        state = OSAllocatedUnfairLock(initialState: State(status: status))
    }

    var reads: Int { state.withLock { $0.reads } }

    func set(_ status: AppleSystemStatus) {
        state.withLock { $0.status = status }
    }

    func currentStatus() -> AppleSystemStatus {
        state.withLock {
            $0.reads += 1
            return $0.status
        }
    }

    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// An `AppleSystemModel` that yields scripted **snapshots**, which is the
/// shape Apple's `streamResponse` produces, and can refuse partway.
struct ScriptedAppleSystemModel: AppleSystemModel {
    var status: AppleSystemStatus = .available
    var snapshots: [String] = []
    var failure: AppleSystemFailure?

    func currentStatus() -> AppleSystemStatus { status }

    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish(throwing: failure)
        }
    }
}

@Suite("AppleFoundationEngine")
struct AppleFoundationEngineTests {
    static func request(_ text: String = "the quick brown fox") -> RewriteRequest {
        RewriteRequest(text: text, preset: .quickImprove)
    }

    /// Apple's API is already snapshot-shaped: `streamResponse` yields the
    /// whole partial response every time, not a delta.
    ///
    /// So this engine forwards what it is given. Adding MLX-style
    /// accumulation here to "make the two engines consistent" would
    /// concatenate the whole output to itself on every token — the scripted
    /// input below would come out as `"Hel"`, `"HelHello"`,
    /// `"HelHelloHello there"`. That is the specific mistake this test exists
    /// to catch, because it looks like a tidy-up.
    @Test("Apple's snapshots are forwarded unchanged, not accumulated a second time")
    func appleSnapshotsAreForwardedUnchanged() async throws {
        let engine = AppleFoundationEngine(
            system: ScriptedAppleSystemModel(snapshots: ["Hel", "Hello", "Hello there"])
        )

        var snapshots: [String] = []
        for try await event in engine.stream(Self.request()) {
            if case .outputSnapshot(let text) = event { snapshots.append(text) }
        }

        #expect(snapshots == ["Hel", "Hello", "Hello there"])
    }

    /// Apple's model can be cut off by its own limits and this engine cannot
    /// tell: `FoundationModels` exposes no stop reason and no token count, so
    /// there is nothing here like the `GenerateStopReason.length` that
    /// `MLXEngine` refuses on. The only remaining signal is the text.
    ///
    /// Without this, the same defect that truncated MLX rewrites is still
    /// live on this engine: a fragment reaches `.finished`, passes
    /// `OutputValidator` — which has no lower bound — and replaces a
    /// paragraph with half a sentence.
    ///
    /// Thrown as `GenerationError`, deliberately not routed through
    /// `AppleEngineError.map`. `map`'s default branch would reduce it to
    /// `.generationFailed("GenerationError")`, whose sentence blames Apple's
    /// model for stopping and offers the local model as the fix — which is
    /// wrong twice, since nothing about Apple caused it and switching engines
    /// will not help.
    @Test("output that stops mid-sentence is refused rather than finished")
    func truncatedOutputIsRefused() async throws {
        let source = "the quarterly report is ready for you to review it now."
        let engine = AppleFoundationEngine(
            system: ScriptedAppleSystemModel(
                snapshots: ["The quarterly", "The quarterly report is ready for your rev"]
            )
        )

        var events: [RewriteEvent] = []
        await #expect(throws: GenerationError.truncated) {
            for try await event in engine.stream(Self.request(source)) { events.append(event) }
        }
        #expect(
            events.allSatisfy { if case .finished = $0 { false } else { true } },
            "a truncated rewrite must never reach the replacement path"
        )
    }

    /// A failure that arrives once generation is under way still has to reach
    /// the user as one of the classified cases, not as whatever raw type the
    /// system threw.
    ///
    /// This matters most for the guardrail, which fires on ordinary prose and
    /// is the case a user is least equipped to interpret. Letting the raw
    /// error through would surface a type nobody can act on, in the one
    /// situation where the difference between "the app broke" and "a content
    /// filter refused this" is the whole message.
    @Test("a guardrail refusal mid-stream surfaces as the classified guardrail error")
    func guardrailRefusalMidStreamSurfacesClassified() async throws {
        let engine = AppleFoundationEngine(
            system: ScriptedAppleSystemModel(
                snapshots: ["Once upon"],
                failure: .guardrailRefusal
            )
        )

        await #expect(throws: AppleEngineError.guardrailRefusal) {
            for try await _ in engine.stream(Self.request()) {}
        }
    }

    /// Apple Intelligence is a toggle in System Settings, and the system can
    /// evict and re-download its model on its own schedule. A user can turn
    /// it off between two hotkey presses.
    ///
    /// So an answer cached at launch is a guess, and the cost of guessing
    /// wrong is an opaque error at the moment someone is trying to get work
    /// done. The read costs a property access.
    ///
    /// The `reads == 2` assertion is what makes this test bite. Without it an
    /// implementation that cached the *first* read would still return the
    /// right answer for call one and could be mistaken for correct.
    @Test("availability is read fresh on every request, never cached")
    func availabilityIsReadFreshOnEveryRequest() async {
        let system = CountingAppleSystemModel(status: .available)
        let engine = AppleFoundationEngine(system: system)

        #expect(await engine.availability() == .ready)

        system.set(.appleIntelligenceNotEnabled)

        #expect(
            await engine.availability()
                == .unavailable(reason: AppleEngineError.appleIntelligenceNotEnabled.message)
        )
        #expect(system.reads == 2)
    }
}
