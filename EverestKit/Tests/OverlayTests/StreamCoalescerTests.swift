import Testing
@testable import Overlay

@Suite("StreamCoalescer")
struct StreamCoalescerTests {
    static let start = ContinuousClock.now

    /// A 4B model on Apple Silicon emits tokens faster than 60 Hz, and every
    /// event carries a full cumulative snapshot, so rendering each one re-lays
    /// out a growing paragraph dozens of times a second on the same thread the
    /// decoder is running on. None of that work reaches the display.
    @Test("a burst of streaming snapshots renders far fewer times than it updates")
    func burstRendersFarFewerTimesThanItUpdates() {
        var coalescer = StreamCoalescer()
        var renders = 0

        for tick in 0 ..< 200 {
            let rendered = coalescer.accept(
                .generating(text: "snapshot \(tick)"),
                at: Self.start + .milliseconds(tick)
            )
            if rendered != nil { renders += 1 }
        }

        #expect(renders > 0)
        #expect(renders < 20)
    }

    /// The failure a naive throttle ships with: the final snapshot arrives
    /// inside the quiet window after the last render, gets held, and nothing
    /// ever comes along to release it. The panel then shows a rewrite that
    /// stops a few words early, and the missing words are the ones the model
    /// worked hardest to produce.
    @Test("the last snapshot in a burst is never dropped")
    func lastSnapshotIsNeverDropped() {
        var coalescer = StreamCoalescer()
        var lastRendered: PanelState?

        for tick in 0 ..< 200 {
            let rendered = coalescer.accept(
                .generating(text: "snapshot \(tick)"),
                at: Self.start + .milliseconds(tick)
            )
            if let rendered { lastRendered = rendered }
        }
        if let flushed = coalescer.flush() { lastRendered = flushed }

        #expect(lastRendered == .generating(text: "snapshot 199"))
    }

    /// Only `generating` is throttled. A terminal state sitting behind a timer
    /// would hold a stale spinner over a finished rewrite, and worse, a
    /// snapshot still queued behind it would land afterwards and overwrite the
    /// result with a half-finished paragraph.
    @Test("a terminal state renders at once and cancels the snapshot waiting behind it")
    func terminalStateBypassesThrottleAndCancelsPending() {
        var coalescer = StreamCoalescer()

        #expect(coalescer.accept(.generating(text: "first"), at: Self.start) == .generating(text: "first"))
        #expect(coalescer.accept(.generating(text: "second"), at: Self.start + .milliseconds(1)) == nil)
        #expect(coalescer.accept(.success, at: Self.start + .milliseconds(2)) == .success)
        #expect(coalescer.flush() == nil)
    }
}
