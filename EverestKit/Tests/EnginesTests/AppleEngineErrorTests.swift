import Testing

@testable import Engines

/// An `AppleSystemModel` fixed in one state, so a test can drive the engine
/// through a condition that would otherwise need a machine with Apple
/// Intelligence switched off, or an ineligible device.
struct StubAppleSystemModel: AppleSystemModel {
    var status: AppleSystemStatus

    func currentStatus() -> AppleSystemStatus { status }

    func stream(
        prompt: String,
        settings: GenerationSettings
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("AppleEngineError")
struct AppleEngineErrorTests {
    /// Five conditions, five fixes: turn on Apple Intelligence, use a
    /// different Mac, wait for the system download, rephrase or switch engine,
    /// select less text. Collapsing them into one "generation failed" sends
    /// the user looking in the wrong place four times out of five.
    ///
    /// The distinctness assertion is the real content here. A mapping that
    /// returned the same sentence for every case would still be
    /// "human-readable" and would still pass a per-case length check.
    @Test("each Apple failure condition maps to its own human-readable message")
    func eachConditionMapsToADistinctMessage() {
        let errors: [AppleEngineError?] = [
            AppleEngineError.blocking(for: StubAppleSystemModel(status: .appleIntelligenceNotEnabled)),
            AppleEngineError.blocking(for: StubAppleSystemModel(status: .deviceNotEligible)),
            AppleEngineError.blocking(for: StubAppleSystemModel(status: .modelNotReady)),
            AppleEngineError.map(AppleSystemFailure.guardrailRefusal),
            AppleEngineError.map(AppleSystemFailure.contextExceeded),
        ]
        let messages = errors.compactMap { $0?.message }

        #expect(messages.count == 5)
        #expect(Set(messages).count == 5)
        #expect(messages.allSatisfy { $0.count >= 20 })

        // An available system is not a failure condition.
        #expect(AppleEngineError.blocking(for: StubAppleSystemModel(status: .available)) == nil)
    }

    /// **An old OS is not an ineligible Mac, and must not say it is.**
    ///
    /// Everest now runs on macOS 14, where `FoundationModels` does not exist.
    /// The nearest existing case is `deviceNotEligible`, and reusing it would
    /// tell an M3 owner their Mac cannot do this when the fix is a software
    /// update they can perform in ten minutes. Root `AGENTS.md` section 6:
    /// a user-facing cause carries its own signal and is never derived from
    /// the nearest available enum.
    ///
    /// The assertion that matters is the third one. A new case that happened
    /// to reuse the ineligible sentence would satisfy the first two.
    @Test("a Mac whose macOS is too old is told to update, not that it is ineligible")
    func tooOldAnOSIsItsOwnCauseAndItsOwnSentence() {
        let blocking = AppleEngineError.blocking(for: StubAppleSystemModel(status: .requiresNewerOS))

        #expect(blocking == .requiresNewerOS, "an unsupported OS must block the request")
        let message = try! #require(blocking?.message)

        #expect(
            message != AppleEngineError.deviceNotEligible.message,
            "reusing the ineligible sentence blames the hardware for a software version"
        )
        #expect(message.contains("26"), "the sentence has to name the version that fixes it")
    }
}
