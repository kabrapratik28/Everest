import CoreGraphics
import Testing
import RewriteCore
@testable import Overlay

/// Stands in for the `NSPanel`. Records what it was asked to draw and where.
@MainActor
final class SpySurface: PanelSurface {
    var height: CGFloat = 120
    var highlightedStyleIndex = 0
    private(set) var presented: [
        (state: PanelState, layout: PanelLayout, followsTail: Bool, acceptsKey: Bool)
    ] = []
    private(set) var measuredWidths: [CGFloat] = []
    /// The highlight in force at each `present`, so a test can see the picker
    /// redraw rather than just the index changing behind it.
    private(set) var presentedHighlights: [Int] = []
    private(set) var hides = 0
    private(set) var appearanceRefreshes = 0

    func refreshAppearance() { appearanceRefreshes += 1 }

    func contentHeight(for state: PanelState, width: CGFloat) -> CGFloat {
        measuredWidths.append(width)
        return height
    }

    func present(_ state: PanelState, layout: PanelLayout, followsTail: Bool, acceptsKey: Bool) {
        presented.append((state, layout, followsTail, acceptsKey))
        presentedHighlights.append(highlightedStyleIndex)
    }

    func hide() { hides += 1 }
}

/// Records install and remove calls so a test can assert they balance.
@MainActor
final class SpyKeyMonitor: KeyMonitoring {
    private(set) var installs = 0
    private(set) var removals = 0
    private var handler: (@MainActor (Keystroke) -> Bool)?

    var isInstalled: Bool { installs > removals }

    func install(_ handler: @escaping @MainActor (Keystroke) -> Bool) -> KeyMonitorHandle {
        installs += 1
        self.handler = handler
        return KeyMonitorHandle { [weak self] in
            self?.removals += 1
            self?.handler = nil
        }
    }

    /// Delivers a keystroke the way a real `NSEvent` monitor would. Returns
    /// whether the panel consumed it.
    @discardableResult
    func send(_ keystroke: Keystroke) -> Bool {
        handler?(keystroke) ?? false
    }
}

/// Time the test controls, and a timer that only fires when the test says so.
@MainActor
final class FakeClock: PanelClock {
    let start: ContinuousClock.Instant
    var now: ContinuousClock.Instant
    private(set) var cancels = 0
    private var pending: (@MainActor () -> Void)?

    var hasPending: Bool { pending != nil }

    init() {
        let instant = ContinuousClock.now
        start = instant
        now = instant
    }

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) {
        pending = body
    }

    func cancel() {
        if pending != nil { cancels += 1 }
        pending = nil
    }

    func fire() {
        let body = pending
        pending = nil
        body?()
    }
}

@MainActor
func makeController(
    surface: PanelSurface = SpySurface(),
    keyMonitor: KeyMonitoring = SpyKeyMonitor(),
    keyInterceptor: KeyMonitoring = SpyKeyMonitor(),
    clock: PanelClock = FakeClock(),
    visibleFrame: @escaping @MainActor () -> CGRect = { FloatingPanelControllerTests.screen }
) -> FloatingPanelController {
    FloatingPanelController(
        surface: surface,
        keyMonitor: keyMonitor,
        keyInterceptor: keyInterceptor,
        clock: clock,
        visibleFrame: visibleFrame
    )
}

@MainActor
@Suite("FloatingPanelController")
struct FloatingPanelControllerTests {
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    /// A global key-down monitor sees every keystroke the user types in every
    /// application for as long as it is installed. This app has no business
    /// holding one except during the seconds a rewrite is on screen, so
    /// installs and removals have to balance on every path.
    @Test("the key monitor is installed on show and removed on dismiss")
    func monitorIsInstalledOnShowAndRemovedOnDismiss() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)

        controller.show(.capturing)
        #expect(monitor.installs == 1)
        #expect(monitor.removals == 0)

        controller.dismiss()
        #expect(monitor.installs == 1)
        #expect(monitor.removals == 1)
        #expect(monitor.isInstalled == false)
    }

    /// Arming twice would install four real `NSEvent` monitors and fire
    /// `onCancel` twice for one Escape. Disarming twice would remove a monitor
    /// that is not there.
    @Test("arming twice installs one monitor and disarming twice removes one")
    func monitorArmingIsIdempotent() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)

        controller.show(.capturing)
        controller.show(.generating(text: "The quick brown fox"))
        #expect(monitor.installs == 1)

        controller.dismiss()
        controller.dismiss()
        #expect(monitor.removals == 1)
        #expect(monitor.isInstalled == false)
    }

    /// The error path is the one most likely to skip teardown, because it is
    /// the path nobody exercises by hand. A monitor left behind here survives
    /// for the rest of the session.
    @Test("a transaction that ends in an error leaves no monitor behind")
    func errorPathLeavesNoMonitorBehind() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)

        controller.show(.capturing)
        controller.update(.error(reason: "the model ran out of memory"))
        controller.dismiss()

        #expect(monitor.isInstalled == false)
        #expect(monitor.installs == monitor.removals)

        controller.show(.capturing)
        #expect(monitor.installs == 2)
        controller.dismiss()
        #expect(monitor.installs == monitor.removals)
    }

    /// "Remember to call remove on every exit path" is a habit, not a
    /// guarantee. The requirement is stronger: there must be no reachable
    /// state in which the monitors are installed and the handle that removes
    /// them has been lost. Dropping the controller on the floor mid-rewrite —
    /// no `dismiss()`, no unwinding — is that state, and it has to clean up.
    @Test("releasing the controller with a panel still up removes the monitors")
    func releasingTheControllerRemovesTheMonitors() {
        let monitor = SpyKeyMonitor()

        do {
            let controller = makeController(keyMonitor: monitor)
            controller.show(.capturing)
            #expect(monitor.installs == 1)
            #expect(monitor.isInstalled)
        }

        #expect(monitor.removals == 1)
        #expect(monitor.isInstalled == false)
    }

    @Test("Escape delivered by the monitor fires onCancel, and stops doing so after dismiss")
    func escapeFiresOnCancelOnlyWhileUp() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let cancels = Counter()
        controller.onCancel = { cancels.bump() }

        controller.show(.capturing)
        monitor.send(PanelKeyMapTests.escape)
        #expect(cancels.count == 1)

        controller.dismiss()
        monitor.send(PanelKeyMapTests.escape)
        #expect(cancels.count == 1)
    }

    @Test("a number key in the picker fires onPickStyle with that row's preset")
    func numberKeyFiresOnPickStyle() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let picked = Box<Preset>()
        controller.onPickStyle = { picked.value = $0 }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        monitor.send(PanelKeyMapTests.digit(3))

        #expect(picked.value == PanelKeyMapTests.fiveStyles[2])
    }

    @Test("copy hands over the held rewrite, and does nothing mid-stream")
    func copyFiresOnlyWhenARewriteIsHeld() {
        let controller = makeController()
        let copied = Box<String>()
        controller.onCopy = { copied.value = $0 }

        controller.show(.generating(text: "half a par"))
        controller.copy()
        #expect(copied.value == nil)

        controller.update(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))
        controller.copy()
        #expect(copied.value == "the whole rewrite")
    }

    @Test("the panel is placed by PanelGeometry on the screen it was handed")
    func panelIsPlacedByGeometry() {
        let screen = CGRect(x: -1728, y: 300, width: 1728, height: 1079)
        let surface = SpySurface()
        surface.height = 120
        let controller = makeController(surface: surface, visibleFrame: { screen })

        controller.show(.capturing)

        #expect(surface.presented.last?.layout.frame == PanelGeometry.layout(contentHeight: 120, in: screen).frame)
        #expect(surface.presented.last?.layout.scrolls == false)
    }

    @Test("update redraws the panel at the new state's content height")
    func updateRedrawsThePanel() {
        let surface = SpySurface()
        surface.height = 120
        let controller = makeController(surface: surface)

        controller.show(.capturing)
        surface.height = 300
        controller.update(.generating(text: "The quick brown fox"))

        #expect(surface.presented.count == 2)
        #expect(surface.presented.last?.state == .generating(text: "The quick brown fox"))
        #expect(surface.presented.last?.layout.frame.height == 300)
    }

    /// The screen is chosen by pointer location, because `NSScreen.main` is the
    /// screen containing the key window and this app deliberately never has
    /// one. That makes the answer change whenever the user moves the mouse, so
    /// it is sampled once and held: a panel growing as text streams in must not
    /// jump to another display half way through.
    @Test("the screen is captured at show, so a growing panel cannot hop displays")
    func screenIsCapturedAtShow() {
        let first = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let second = CGRect(x: 4000, y: 0, width: 1000, height: 800)
        let pointerScreen = Box<CGRect>()
        pointerScreen.value = first

        let surface = SpySurface()
        surface.height = 120
        let controller = makeController(surface: surface, visibleFrame: { pointerScreen.value ?? .zero })

        controller.show(.capturing)
        pointerScreen.value = second
        surface.height = 300
        controller.update(.generating(text: "The quick brown fox"))

        #expect(surface.presented.last?.layout.frame == PanelGeometry.layout(contentHeight: 300, in: first).frame)
    }

    @Test("dismiss takes the panel off screen, once")
    func dismissHidesThePanelOnce() {
        let surface = SpySurface()
        let controller = makeController(surface: surface)

        controller.show(.capturing)
        controller.dismiss()
        #expect(surface.hides == 1)

        controller.dismiss()
        #expect(surface.hides == 1)
    }

    @Test("Return picks the highlighted row, which starts on the first style")
    func returnPicksTheHighlightedRow() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let picked = Box<Preset>()
        controller.onPickStyle = { picked.value = $0 }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        monitor.send(PanelKeyMapTests.enter)

        #expect(picked.value == PanelKeyMapTests.fiveStyles[0])
    }

    @Test("the arrow keys move the highlight and stop at both ends")
    func arrowKeysMoveTheHighlight() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))

        #expect(controller.highlightedStyleIndex == 0)

        monitor.send(PanelKeyMapTests.arrowUp)
        #expect(controller.highlightedStyleIndex == 0)

        monitor.send(PanelKeyMapTests.arrowDown)
        monitor.send(PanelKeyMapTests.arrowDown)
        #expect(controller.highlightedStyleIndex == 2)

        for _ in 0 ..< 10 { monitor.send(PanelKeyMapTests.arrowDown) }
        #expect(controller.highlightedStyleIndex == 4)
    }

    /// The accessibility settings are sampled once per presentation rather
    /// than observed, because an observer is another thing whose lifetime has
    /// to be managed on the same paths that already manage the key monitors.
    /// Re-sampling on every streamed token would also be a `NSWorkspace` round
    /// trip per frame.
    @Test("the accessibility settings are re-read once per presentation, not per update")
    func appearanceIsSampledOncePerPresentation() {
        let surface = SpySurface()
        let controller = makeController(surface: surface)

        controller.show(.capturing)
        #expect(surface.appearanceRefreshes == 1)

        controller.update(.generating(text: "one"))
        controller.update(.success)
        #expect(surface.appearanceRefreshes == 1)

        controller.dismiss()
        controller.show(.capturing)
        #expect(surface.appearanceRefreshes == 2)
    }

    /// A non-activating panel does receive mouse events without activating the
    /// app, so rows are clickable. That path does not go through the key map,
    /// so it needs its own bounds check.
    @Test("picking a row directly fires onPickStyle, and an index outside the list does nothing")
    func pickingARowDirectlyFiresOnPickStyle() {
        let controller = makeController()
        let picked = Box<Preset>()
        controller.onPickStyle = { picked.value = $0 }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))

        controller.pickStyle(at: 99)
        #expect(picked.value == nil)

        controller.pickStyle(at: 3)
        #expect(picked.value == PanelKeyMapTests.fiveStyles[3])
    }

    /// An arrow key that moves an index nobody draws is an invisible cursor.
    @Test("moving the highlight redraws the picker with the new row marked")
    func movingTheHighlightReachesTheSurface() {
        let monitor = SpyKeyMonitor()
        let surface = SpySurface()
        let controller = makeController(surface: surface, keyMonitor: monitor)

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        #expect(surface.presentedHighlights.last == 0)

        monitor.send(PanelKeyMapTests.arrowDown)
        #expect(surface.presentedHighlights.last == 1)
    }

    @Test("a new picker starts on the first row again")
    func showResetsTheHighlight() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        monitor.send(PanelKeyMapTests.arrowDown)
        monitor.send(PanelKeyMapTests.arrowDown)
        #expect(controller.highlightedStyleIndex == 2)

        controller.dismiss()
        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        #expect(controller.highlightedStyleIndex == 0)
    }

    /// The throttle only earns its place if `update` actually goes through it,
    /// and it is only safe if the timer that releases the held snapshot really
    /// gets scheduled. Both halves are asserted here.
    @Test("streaming updates are coalesced and the last one still reaches the panel")
    func streamingUpdatesAreCoalesced() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        controller.show(.capturing)
        let beforeStream = surface.presented.count

        for tick in 0 ..< 100 {
            clock.now = clock.start + .milliseconds(tick)
            controller.update(.generating(text: "snapshot \(tick)"))
        }

        let rendersDuringStream = surface.presented.count - beforeStream
        #expect(rendersDuringStream > 0)
        #expect(rendersDuringStream < 15)

        #expect(clock.hasPending)
        clock.fire()
        #expect(surface.presented.last?.state == .generating(text: "snapshot 99"))
    }

    /// Consuming is the whole point. If the panel is not key, our monitor sees
    /// ⌘C and so does the frontmost app — and that app's own copy lands *after*
    /// ours and overwrites the rewrite we just put on the clipboard.
    @Test("Command-C copies and is consumed in a key terminal state, and does nothing before one")
    func commandCCopiesAndIsConsumedOnlyInATerminalState() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let copied = Box<String>()
        controller.onCopy = { copied.value = $0 }

        controller.show(.generating(text: "half a par"))
        #expect(monitor.send(PanelKeyMapTests.commandC) == false)
        #expect(copied.value == nil)

        controller.update(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))
        #expect(monitor.send(PanelKeyMapTests.commandC) == true)
        #expect(copied.value == "the whole rewrite")
    }

    /// Escape works everywhere, but a non-key panel cannot swallow it. Saying
    /// otherwise would make the local monitor eat an event the frontmost app
    /// should still see. A leaked Escape is harmless; a lie here is not.
    @Test("Escape cancels in a non-key state without claiming to consume the event")
    func escapeCancelsWithoutConsumingWhenNotKey() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let cancels = Counter()
        controller.onCancel = { cancels.bump() }

        controller.show(.generating(text: "half a par"))

        #expect(monitor.send(PanelKeyMapTests.escape) == false)
        #expect(cancels.count == 1)
    }

    /// The `esc Cancel` row is clickable, and a click does not go through the
    /// key map. It has to reach the same place Escape does, or the mouse and
    /// the keyboard drift apart.
    @Test("cancel fires onCancel, the same as Escape does")
    func cancelFiresOnCancel() {
        let controller = makeController()
        let cancels = Counter()
        controller.onCancel = { cancels.bump() }

        controller.show(.generating(text: "half a par"))
        controller.cancel()

        #expect(cancels.count == 1)
    }

    /// The decision is `PanelState.acceptsKeyWindow`; this is the wiring that
    /// carries it to the window. If the window never hears about it, ⌘C is
    /// never consumed and the frontmost app's copy overwrites ours.
    @Test("the surface is told, per state, whether the panel may take key status")
    func keyStatusFollowsTheState() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        controller.show(.capturing)
        #expect(surface.presented.last?.acceptsKey == false)

        clock.now = clock.start + .seconds(1)
        controller.update(.generating(text: "half a par"))
        #expect(surface.presented.last?.acceptsKey == false)

        clock.now = clock.start + .seconds(2)
        controller.update(.heldForManualCopy(text: "the rewrite", reason: "the window moved"))
        #expect(surface.presented.last?.acceptsKey == true)

        clock.now = clock.start + .seconds(3)
        controller.update(.success)
        #expect(surface.presented.last?.acceptsKey == false)
    }

    /// Auto-scrolling to the newest text is right while the user is watching
    /// it arrive and wrong the moment they scroll up to re-read something.
    /// Yanking someone back to the bottom mid-sentence is worse than never
    /// following at all.
    @Test("streaming follows the tail until the user scrolls away, and resumes at the bottom")
    func tailFollowingYieldsToTheUser() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        controller.show(.capturing)
        #expect(controller.followsTail)
        #expect(surface.presented.last?.followsTail == true)

        controller.userScrolled(isAtBottom: false)
        clock.now = clock.start + .seconds(1)
        controller.update(.generating(text: "one"))
        #expect(controller.followsTail == false)
        #expect(surface.presented.last?.followsTail == false)

        controller.userScrolled(isAtBottom: true)
        clock.now = clock.start + .seconds(2)
        controller.update(.generating(text: "two"))
        #expect(controller.followsTail)
        #expect(surface.presented.last?.followsTail == true)

        // A fresh panel follows again, whatever the last one ended on.
        controller.userScrolled(isAtBottom: false)
        controller.dismiss()
        controller.show(.capturing)
        #expect(controller.followsTail)
        #expect(surface.presented.last?.followsTail == true)
    }

    /// An event tap is strictly more dangerous than the global monitor beside
    /// it: while it exists it can *delete* keystrokes out of every application
    /// on the machine. It has no business existing outside the seconds the
    /// picker is on screen, so its lifetime is tied to that one state rather
    /// than to the transaction the way the monitors are.
    @Test("the event tap is armed only while the picker is on screen")
    func tapIsArmedOnlyForThePicker() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)

        controller.show(.capturing)
        #expect(tap.installs == 0)

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        #expect(tap.installs == 1)

        // A style was picked and the rewrite has started. Nothing is waiting
        // for picker keys any more, so nothing may still be swallowing them.
        controller.update(.generating(text: "The quick"))
        #expect(tap.isInstalled == false)

        controller.dismiss()
        #expect(tap.installs == tap.removals)
    }

    /// The bug this exists for. The panel is deliberately not key while the
    /// picker is up, so every key the picker uses was *also* being delivered to
    /// the app underneath: the arrows moved that app's caret and collapsed the
    /// very selection about to be rewritten, and a bare digit replaced the
    /// selected text outright. A tap consumes by deleting the event from the
    /// stream, which costs nothing in focus, so here the answer is yes.
    @Test("the picker's keys are consumed, so the app underneath never sees them")
    func pickerKeysAreConsumed() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let picked = Box<Preset>()
        let cancels = Counter()
        controller.onPickStyle = { picked.value = $0 }
        controller.onCancel = { cancels.bump() }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))

        #expect(tap.send(PanelKeyMapTests.arrowDown) == true)
        #expect(tap.send(PanelKeyMapTests.arrowUp) == true)
        #expect(tap.send(PanelKeyMapTests.enter) == true)
        #expect(tap.send(PanelKeyMapTests.escape) == true)

        // Swallowed *and* acted on. Consuming without acting would be a picker
        // that eats the user's keys and does nothing with them.
        #expect(tap.send(PanelKeyMapTests.digit(3)) == true)
        #expect(picked.value == PanelKeyMapTests.fiveStyles[2])
        #expect(cancels.count == 1)
    }

    /// The other half of the same guard, and the more dangerous half. While the
    /// tap is up it is the first thing in the session to see every keystroke
    /// the user types, in any application. A tap that swallowed anything beyond
    /// the picker's own keys would be a keyboard that stops working for as long
    /// as the panel is on screen.
    @Test("a key the picker does not use passes through the tap untouched")
    func nonPickerKeysPassThroughTheTap() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let picked = Box<Preset>()
        controller.onPickStyle = { picked.value = $0 }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))

        let bareZ = Keystroke(keyCode: 6, characters: "z", modifiers: [])
        #expect(tap.send(bareZ) == false)
        // ⌘3 switches a browser tab; ⇧3 types a `#`. Neither is a pick.
        #expect(tap.send(PanelKeyMapTests.digit(3, plain: false)) == false)
        #expect(tap.send(Keystroke(keyCode: 0, characters: "3", modifiers: .shift)) == false)
        // The picker holds no rewrite, so ⌘C here is the user copying in the
        // app underneath. Eating it would lose them their own clipboard.
        #expect(tap.send(PanelKeyMapTests.commandC) == false)
        // A digit past the end of the list is not a row.
        #expect(tap.send(PanelKeyMapTests.digit(9)) == false)

        #expect(picked.value == nil)
    }

    /// Same requirement as the monitors, and the existing test for them does
    /// not cover this: it never opens the picker, so it never installs a tap.
    /// The handler is retained by the handle and the handle by the controller,
    /// so a handler holding the controller strongly is a cycle — the controller
    /// never deallocates and the tap survives for the rest of the session,
    /// deleting keys out of every application the user types in.
    @Test("releasing the controller with the picker up removes the event tap")
    func releasingTheControllerRemovesTheTap() {
        let tap = SpyKeyMonitor()

        do {
            let controller = makeController(keyInterceptor: tap)
            controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
            #expect(tap.isInstalled)
        }

        #expect(tap.removals == 1)
        #expect(tap.isInstalled == false)
    }

    /// The coordinator drives the panel straight from engine events, so that
    /// entry point has to go through the same throttle. A second, unthrottled
    /// path would put the per-token relayout back.
    @Test("update(from:) maps the event and goes through the same throttle")
    func updateFromEventUsesTheSamePath() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        controller.show(.capturing)
        let beforeStream = surface.presented.count

        for tick in 0 ..< 100 {
            clock.now = clock.start + .milliseconds(tick)
            controller.update(from: .outputSnapshot("snapshot \(tick)"))
        }

        #expect(surface.presented.count - beforeStream < 15)

        clock.fire()
        #expect(surface.presented.last?.state == .generating(text: "snapshot 99"))
    }
}

@MainActor
final class Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@MainActor
final class Box<Value> {
    var value: Value?
}
