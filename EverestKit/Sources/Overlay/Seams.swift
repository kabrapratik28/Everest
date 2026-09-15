import CoreGraphics

// The complete boundary between this target and the parts of macOS that need a
// window server, a logged-in session, or real elapsed time. Everything above
// these three protocols is a decision and has a test. Everything below them is
// in `NSPanelSurface`, `NSEventKeyMonitor` and `RunLoopPanelClock`, decides
// nothing, and is verified by hand.
//
// They live in one file on purpose: the seams are a set, and seeing them
// together tells the next person exactly how large the untested surface is.

// MARK: - The window

/// Draws the panel. Told what to draw and where; never works either out.
@MainActor
public protocol PanelSurface: AnyObject {
    /// Which picker row to mark. Set by the controller before every `present`,
    /// because the arrows move a number and the surface has to draw it.
    var highlightedStyleIndex: Int { get set }

    /// Re-read the accessibility settings. Called once per presentation.
    func refreshAppearance()

    /// Height this state's content needs when laid out at `width`.
    func contentHeight(for state: PanelState, width: CGFloat) -> CGFloat

    /// Draw `state`. `layout.frame` is the window; `layout.contentHeight` is
    /// the document behind it, which is taller once the cap bites.
    /// `followsTail` asks the scroll position to stay pinned to the newest
    /// text — false once the user has scrolled up to read. `acceptsKey` is
    /// `PanelState.acceptsKeyWindow`: true only in terminal states, where
    /// taking focus no longer costs the user their selection.
    func present(_ state: PanelState, layout: PanelLayout, followsTail: Bool, acceptsKey: Bool)

    /// Speak this to a screen reader.
    ///
    /// Separate from `present` because it happens far less often: the panel is
    /// redrawn per streamed token and announced once per state. It exists at
    /// all because a non-activating panel takes no focus, so VoiceOver never
    /// visits it on its own and every label inside `RewriteView` goes unread —
    /// the announcement is the only thing that reaches a screen reader user.
    /// *When* to call it is a decision and lives in `FloatingPanelController`.
    func announce(_ value: String)

    func hide()
}

// MARK: - The keyboard

/// Owns installed key monitors. Releasing this removes them; there is no other
/// way to remove them and no other way to keep them alive.
///
/// The point is that teardown is not a call anyone can forget. The controller
/// holds exactly one optional reference: clearing it removes the monitors, and
/// releasing the controller removes them too, because ARC releases the handle
/// either way. There is no reachable state where the monitors are installed
/// and the handle to them has been lost.
@MainActor
public final class KeyMonitorHandle {
    private let teardown: @MainActor () -> Void

    public init(teardown: @escaping @MainActor () -> Void) {
        self.teardown = teardown
    }

    isolated deinit { teardown() }
}

/// A global key-down monitor is the most sensitive thing this app ever holds:
/// while it is installed it observes every keystroke the user types in every
/// application. Putting it behind a protocol makes the balance between install
/// and remove something a test can assert, instead of something a reviewer has
/// to trace by eye.
/// The handler returns true when the panel consumed the keystroke, which the
/// local monitor turns into swallowing the event. Only a key window can
/// genuinely consume, so a non-key panel must return false even when it acted
/// — otherwise the local monitor eats an event the frontmost app should see.
@MainActor
public protocol KeyMonitoring: AnyObject {
    func install(_ handler: @escaping @MainActor (Keystroke) -> Bool) -> KeyMonitorHandle
}

// MARK: - Time

/// The streaming throttle is a decision about *when*, so injecting time is what
/// makes it testable: a hundred-update burst replays in microseconds instead of
/// a second and a half of real waiting, and the flush timer fires exactly when
/// the test says it does rather than whenever the run loop gets round to it.
@MainActor
public protocol PanelClock: AnyObject {
    var now: ContinuousClock.Instant { get }

    /// Runs `body` after `delay`, replacing anything previously scheduled.
    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void)

    func cancel()
}
