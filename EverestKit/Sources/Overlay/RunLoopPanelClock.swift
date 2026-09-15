import Foundation

/// The real `PanelClock`. Integration only: the throttle's decisions are tested
/// against `FakeClock`, and this class just turns them into a `Timer`.
@MainActor
public final class RunLoopPanelClock: PanelClock {
    private var timer: Timer?

    public init() {}

    public var now: ContinuousClock.Instant { .now }

    public func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) {
        cancel()
        let timer = Timer(timeInterval: delay.seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        // `.common`, not `.default`. A default-mode timer stops firing while
        // the user holds a scroll gesture or has a menu open, which would
        // freeze the streaming text mid-rewrite for as long as they hold it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
