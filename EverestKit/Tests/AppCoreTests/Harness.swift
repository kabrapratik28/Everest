import ApplicationServices
import CoreGraphics
import Foundation
import Overlay
import RewriteCore
import Synchronization
import TextBridge

@testable import AppCore

// The coordinator's whole job is ordering: capture, then panel, then engine,
// then validation, then replacement, then a terminal state. So the doubles here
// record *when* they were called as well as *what with*, and most assertions in
// this suite are about a sequence rather than a value.

/// One ordered record of everything the coordinator did to the outside world.
///
/// Shared by every double, so `capture` and `present` land in the same list and
/// their relative order is directly assertable. That order is a guard, not a
/// detail: showing a panel before the selection is read perturbs accessibility
/// focus, and for the style picker the tap that consumes digits is
/// signature-keyed — without the grant a `3` typed at the picker also lands in
/// the text about to be rewritten.
@MainActor
final class CallLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) { entries.append(entry) }
}

/// Stands in for the `NSPanel`. Records what it was asked to draw, in order.
@MainActor
final class SpySurface: PanelSurface {
    let log: CallLog
    var highlightedStyleIndex = 0
    private(set) var presented: [PanelState] = []
    private(set) var hides = 0

    init(log: CallLog) { self.log = log }

    func refreshAppearance() {}

    /// Empty, like `refreshAppearance`. *When* the panel announces itself is
    /// `FloatingPanelController`'s decision and `OverlayTests` owns it;
    /// recording it into the shared `CallLog` here would insert an entry
    /// between every state and the assertions in this suite are about the
    /// order of capture, present, apply and hide.
    func announce(_ value: String) {}

    func contentHeight(for state: PanelState, width: CGFloat) -> CGFloat { 120 }

    func present(_ state: PanelState, layout: PanelLayout, followsTail: Bool, acceptsKey: Bool) {
        presented.append(state)
        log.record("present(\(state.kind.rawValue))")
    }

    func hide() {
        hides += 1
        log.record("hide")
    }
}

/// The panel's own key monitor. This suite does not drive keystrokes through
/// it — that is `OverlayTests`' job — it only has to exist so the controller
/// under test is the real one.
@MainActor
final class StubKeyMonitor: KeyMonitoring {
    func install(_ handler: @escaping @MainActor (Keystroke) -> Bool) -> KeyMonitorHandle {
        KeyMonitorHandle {}
    }
}

/// The panel's own throttle clock. Never fires here: terminal states are not
/// throttled, and this suite asserts on terminal states.
@MainActor
final class StubPanelClock: PanelClock {
    var now: ContinuousClock.Instant = .now

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) {}

    func cancel() {}
}

// MARK: - Building the thing under test

@MainActor
func makePanel(log: CallLog) -> (FloatingPanelController, SpySurface) {
    let surface = SpySurface(log: log)
    let panel = FloatingPanelController(
        surface: surface,
        keyMonitor: StubKeyMonitor(),
        // The consuming interceptor the style picker arms so its digits and
        // arrows do not also reach the app being rewritten. AppCore's tests
        // never exercise it; a second stub keeps them honest about that.
        keyInterceptor: StubKeyMonitor(),
        clock: StubPanelClock(),
        visibleFrame: { CGRect(x: 0, y: 0, width: 1728, height: 1079) }
    )
    return (panel, surface)
}

/// A settings object on a throwaway `UserDefaults` suite, so a test never reads
/// or writes the real user's defaults.
@MainActor
func makeSettings() -> AppSettings {
    AppSettings(store: UserDefaults(suiteName: "com.kabrapratik.Everest.appcore.\(UUID().uuidString)")!)
}

/// Everything a coordinator needs, defaulted, so adding a dependency touches
/// one place rather than every test.
@MainActor
func makeCoordinator(
    panel: FloatingPanelController,
    settings: AppSettings,
    snapshot: TargetSnapshot = .stub(),
    capture: (@MainActor @Sendable ([String]) throws -> TargetSnapshot)? = nil,
    engine: any RewriteEngine = StubEngine(),
    apply: ApplyRecorder,
    sleeper: RecordingSleeper = RecordingSleeper()
) -> RewriteCoordinator {
    RewriteCoordinator(
        panel: panel,
        settings: settings,
        capture: capture ?? { _ in snapshot },
        engineFor: { _ in engine },
        apply: { text, target in apply.apply(text, to: target) },
        sleeper: sleeper
    )
}

/// A selection that changes between reads.
///
/// The second text models the stray digit: the tap that consumes the `3`
/// picking style 3 needs a signature-keyed grant, and without it the digit
/// also lands in the app being rewritten. A coordinator that re-read the
/// selection after the pick would rewrite the corrupted text.
@MainActor
final class CaptureSource {
    private let texts: [String]
    private(set) var count = 0
    /// The exclusion list handed to each capture, in order.
    private(set) var exclusions: [[String]] = []

    init(_ texts: [String] = ["original text"]) { self.texts = texts }

    func next(excluding excluded: [String]) -> TargetSnapshot {
        exclusions.append(excluded)
        defer { count += 1 }
        return .stub(text: texts[min(count, texts.count - 1)])
    }
}

/// Hands out a different engine per transaction, so a superseded generation
/// and the one that replaced it can be told apart.
final class EngineQueue: Sendable {
    private let remaining: Mutex<[any RewriteEngine]>
    private let last: any RewriteEngine

    init(_ engines: [any RewriteEngine]) {
        precondition(!engines.isEmpty)
        remaining = Mutex(engines)
        last = engines[engines.count - 1]
    }

    func next() -> any RewriteEngine {
        remaining.withLock { $0.isEmpty ? last : $0.removeFirst() }
    }
}

/// Stands in for the auto-dismiss wait, and returns immediately.
///
/// A test that really slept 1.2 seconds would take 1.2 seconds and prove less:
/// what matters is *which* interval was asked for and that the panel was still
/// up when the wait started, both of which are visible here. The wait is
/// recorded into the shared `CallLog` so the order — state, then wait, then
/// hide — is assertable rather than inferred.
final class RecordingSleeper: Sleeping {
    private let state = Mutex([Duration]())
    private let log: CallLog?

    /// `nil` when a test does not care about ordering. `CallLog` is
    /// `@MainActor`, so recording is hopped rather than done inline.
    init(log: CallLog? = nil) { self.log = log }

    var requested: [Duration] { state.withLock { $0 } }

    func sleep(for duration: Duration) async {
        state.withLock { $0.append(duration) }
        if let log { await MainActor.run { log.record("wait") } }
    }
}

/// Something `capture()` is not documented to throw, for the fallback path.
enum UnexpectedFailure: Error { case somethingElse }


/// Records what the coordinator handed to `ReplacementService`, and what it
/// was told in return.
@MainActor
final class ApplyRecorder {
    let log: CallLog
    var outcome: ReplaceOutcome = .replaced
    private(set) var applied: [String] = []

    init(log: CallLog, outcome: ReplaceOutcome = .replaced) {
        self.log = log
        self.outcome = outcome
    }

    func apply(_ text: String, to snapshot: TargetSnapshot) -> ReplaceOutcome {
        applied.append(text)
        log.record("apply")
        return outcome
    }
}

/// A `RewriteEngine` that yields scripted events.
///
/// Real inference needs 2.3 GB of weights and a Metal device; the coordinator's
/// own logic — what it does with `.finished`, what it does when superseded —
/// is entirely driveable here. `gate` lets a test hold the stream open long
/// enough to press the hotkey a second time.
final class StubEngine: RewriteEngine {
    let id: EngineID
    private let events: [RewriteEvent]
    private let progressSteps: [Double]
    private let prepareFailure: (any Error)?
    private let reported: EngineAvailability
    private let failure: (any Error)?
    private let state = Mutex(State())

    struct State {
        var cancels = 0
        var prepares = 0
        var streamed = 0
        var requests: [RewriteRequest] = []
    }

    /// Signalled once the stream has yielded its first event, so a test can
    /// supersede a generation that is genuinely in flight.
    private let opened = AsyncStream<Void>.makeStream()
    /// Held closed until `release()`, keeping the stream open in between.
    private let gate = AsyncStream<Void>.makeStream()
    private let gated: Bool

    /// The same trick for `prepare`, so a test can press Escape partway
    /// through a download. `prepare` reports the first progress step, waits
    /// here, then reports the rest — which is the interleaving that matters:
    /// the question is what the coordinator does with a percentage that
    /// arrives *after* the transaction it belongs to has been cancelled.
    private let prepareGate = AsyncStream<Void>.makeStream()
    private let preparingSignal = AsyncStream<Void>.makeStream()
    private let prepareGated: Bool

    init(
        id: EngineID = .qwen4B,
        events: [RewriteEvent] = [],
        progressSteps: [Double] = [],
        availability: EngineAvailability = .ready,
        prepareFailure: (any Error)? = nil,
        failure: (any Error)? = nil,
        gated: Bool = false,
        prepareGated: Bool = false
    ) {
        self.id = id
        self.events = events
        self.progressSteps = progressSteps
        self.reported = availability
        self.prepareFailure = prepareFailure
        self.failure = failure
        self.gated = gated
        self.prepareGated = prepareGated
    }

    var cancels: Int { state.withLock(\.cancels) }
    var prepares: Int { state.withLock(\.prepares) }
    var streamed: Int { state.withLock(\.streamed) }
    var requests: [RewriteRequest] { state.withLock(\.requests) }

    /// Returns once the stream is running and has emitted its first event.
    func waitUntilStreaming() async {
        var iterator = opened.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { gate.continuation.finish() }

    func availability() async -> EngineAvailability { reported }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0.prepares += 1 }
        guard prepareGated else {
            for step in progressSteps { progress(step) }
            if let prepareFailure { throw prepareFailure }
            return
        }
        // First step, then hold, then the rest: a download the user cancels
        // halfway reports more progress on its way out.
        if let first = progressSteps.first { progress(first) }
        preparingSignal.continuation.yield(())
        for await _ in prepareGate.stream {}
        for step in progressSteps.dropFirst() { progress(step) }
        if let prepareFailure { throw prepareFailure }
    }

    /// Returns once `prepare` has reported its first step and is holding.
    func waitUntilPreparing() async {
        var iterator = preparingSignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func stream(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error> {
        state.withLock {
            $0.streamed += 1
            $0.requests.append(request)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                    opened.continuation.yield(())
                    if gated {
                        for await _ in gate.stream {}
                    }
                }
                opened.continuation.yield(())
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() async {
        state.withLock { $0.cancels += 1 }
        gate.continuation.finish()
        prepareGate.continuation.finish()
    }
}

extension TargetSnapshot {
    /// A snapshot that would pass every one of `ReplacementService`'s checks.
    /// `AXUIElementCreateApplication` needs no permission and no live app.
    static func stub(text: String = "original text", pid: pid_t = 501) -> TargetSnapshot {
        TargetSnapshot(
            pid: pid,
            bundleID: "com.example.editor",
            appVersion: "1.0",
            element: AXUIElementCreateApplication(pid),
            text: text,
            range: CFRange(location: 0, length: text.utf16.count),
            role: "AXTextArea",
            isEditable: true,
            isRangeDerived: false
        )
    }
}
