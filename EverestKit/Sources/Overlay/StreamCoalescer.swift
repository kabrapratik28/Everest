/// Rate-limits streaming panel updates to about one display frame.
///
/// Pure and time-injected: `accept` is told what time it is rather than asking,
/// so a two-hundred-update burst can be replayed in a test in microseconds. The
/// controller owns the timer that turns `dueAt` into a real flush; this type
/// owns the decision.
public struct StreamCoalescer: Sendable {
    /// Roughly one frame at 60 Hz. Below this the display cannot show the
    /// difference, so the layout work is spent for nothing.
    public static let defaultInterval: Duration = .milliseconds(16)

    private let interval: Duration
    private var lastRenderAt: ContinuousClock.Instant?
    private var held: PanelState?

    public init(interval: Duration = StreamCoalescer.defaultInterval) {
        self.interval = interval
    }

    /// Returns the state to render now, or `nil` to hold it back.
    public mutating func accept(
        _ state: PanelState,
        at now: ContinuousClock.Instant
    ) -> PanelState? {
        guard case .generating = state else {
            held = nil
            lastRenderAt = now
            return state
        }
        if let lastRenderAt, now - lastRenderAt < interval {
            held = state
            return nil
        }
        held = nil
        lastRenderAt = now
        return state
    }

    /// Releases whatever `accept` held back, or `nil` if nothing is waiting.
    ///
    /// Dropping an intermediate snapshot is free: the next one is a superset of
    /// it. Dropping the *last* one is not, because there is no next one. This
    /// is the method that makes the difference, and the controller must call it
    /// off a timer for it to mean anything.
    public mutating func flush() -> PanelState? {
        defer { held = nil }
        return held
    }
}
