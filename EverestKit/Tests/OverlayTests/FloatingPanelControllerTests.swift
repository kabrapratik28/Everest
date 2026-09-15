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
    private(set) var announced: [String] = []

    func refreshAppearance() { appearanceRefreshes += 1 }

    func announce(_ value: String) { announced.append(value) }

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

    /// The monitors act on ⌘C but never claim it, in any state.
    ///
    /// They did claim it in terminal states, back when the panel made itself
    /// key there — and only a key window can genuinely swallow an event, so
    /// the claim was true at the time. It is not any more: the panel is never
    /// key, and saying otherwise would have the local monitor eat a ⌘C the
    /// frontmost app should see. Taking it from the source app is the tap's
    /// job now, in `statesHoldingARewriteConsumeOnlyCommandC`.
    @Test("Command-C copies where there is a rewrite, and the monitors never claim it")
    func commandCCopiesWithoutTheMonitorsClaimingIt() {
        let monitor = SpyKeyMonitor()
        let controller = makeController(keyMonitor: monitor)
        let copied = Box<String>()
        controller.onCopy = { copied.value = $0 }

        controller.show(.generating(text: "half a par"))
        #expect(monitor.send(PanelKeyMapTests.commandC) == false)
        #expect(copied.value == nil)

        controller.update(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))
        #expect(monitor.send(PanelKeyMapTests.commandC) == false)
        // Positive control: it acted, so the false above is a verdict about
        // claiming rather than a keystroke that went nowhere.
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

        // A fresh picker per key. The picker answers once, so the keys that
        // answer it cannot be sent in a row at the same one — doing that was
        // this test relying on a picker that could be answered three times.
        for keystroke in [
            PanelKeyMapTests.arrowDown,
            PanelKeyMapTests.arrowUp,
            PanelKeyMapTests.enter,
            PanelKeyMapTests.escape,
            PanelKeyMapTests.digit(3),
        ] {
            controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
            #expect(tap.send(keystroke) == true, "\(keystroke.characters)")
        }

        // Swallowed *and* acted on. Consuming without acting would be a picker
        // that eats the user's keys and does nothing with them.
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

        let unclaimed = [
            Keystroke(keyCode: 6, characters: "z", modifiers: []),
            // ⌘3 switches a browser tab; ⇧3 types a `#`. Neither is a pick.
            PanelKeyMapTests.digit(3, plain: false),
            Keystroke(keyCode: 0, characters: "3", modifiers: .shift),
            // The picker holds no rewrite, so ⌘C here is the user copying in
            // the app underneath. Eating it would lose them their clipboard.
            PanelKeyMapTests.commandC,
            // A digit past the end of the list is not a row.
            PanelKeyMapTests.digit(9),
        ]

        // A fresh picker per key, because the first unclaimed key now ends the
        // picker and disarms the tap. Sending them in a row would leave keys
        // two onward hitting no handler at all and returning false for that
        // reason, so the test would keep passing while testing nothing.
        for keystroke in unclaimed {
            controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
            #expect(tap.isInstalled)
            #expect(tap.send(keystroke) == false, "\(keystroke.characters)")
        }

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

    /// What bounds the tap's life, given the picker has no timer.
    ///
    /// `stylePicker.autoDismissAfter` is `nil`, so a picker the user walks away
    /// from would hold a session-wide tap open indefinitely — and that tap
    /// swallows digits, arrows and Return. Walk away, switch to Slack, type
    /// "there at 3": the `3` never arrives, and it picks a style and starts
    /// rewriting a selection captured minutes ago. So the picker is treated as
    /// a question: anything that is not an answer to it means the user has
    /// moved on, so the picker ends and the coordinator takes the panel down.
    @Test("a key the picker cannot answer ends the picker instead of holding the tap open")
    func anUnclaimedKeyEndsThePicker() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let cancels = Counter()
        controller.onCancel = { cancels.bump() }

        controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
        #expect(tap.isInstalled)

        // Still passes through — ending the picker is not a reason to eat the
        // keystroke the user was actually typing. `cancels` is the positive
        // control: it proves the handler ran rather than the spy being dead.
        #expect(tap.send(PanelKeyMapTests.bareZ) == false)
        #expect(cancels.count == 1)

        // The tap is *not* dropped on the spot. Doing that raced the gap
        // before the coordinator can dismiss and reopened the original bug —
        // see `thePickerAnswersOnce`. Its life is bound by `state.didSet` and
        // `dismiss()`, the same guarantee the monitors have.
        #expect(tap.isInstalled)
        controller.dismiss()
        #expect(tap.isInstalled == false)
    }

    /// This app is built on the Accessibility API, and until now nothing it
    /// showed was announced to a screen reader. A non-activating panel takes
    /// no focus, so VoiceOver never visits it: every message, including every
    /// refusal and error reason we wrote carefully, was silent. The labels in
    /// `RewriteView` only pay off once something says the panel is there.
    ///
    /// Once per *kind*, not once per update, for the reason `accessibilityValue`
    /// already omits the streaming text: snapshots arrive dozens of times a
    /// second and VoiceOver restarts its utterance on each one, so announcing
    /// per update would read the first three words over and over.
    @Test("each new state is announced once, and a streaming burst is announced once in total")
    func statesAreAnnouncedOncePerKind() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        controller.show(.capturing)
        #expect(surface.announced == ["Reading selection"])

        for tick in 0 ..< 50 {
            clock.now = clock.start + .milliseconds(tick)
            controller.update(.generating(text: "snapshot \(tick)"))
        }
        clock.fire()
        #expect(surface.announced == ["Reading selection", "Rewriting"])

        // The reason has to be spoken, not just the headline — a reason nobody
        // can hear is not a reason.
        clock.now = clock.start + .seconds(1)
        controller.update(.error(reason: "the model ran out of memory"))
        #expect(surface.announced.last == "Rewrite failed. the model ran out of memory")
    }

    /// The picker is a question, and a question is answered once.
    ///
    /// Nothing in this target can dismiss the panel — only the coordinator
    /// can, and it gets there through an `await`. So for the width of at least
    /// one actor hop after the picker has been answered, `state` is still
    /// `.stylePicker` and every picker key still resolves to an action. A
    /// digit arriving in that gap started a second rewrite of a selection the
    /// user had already finished with; and where the gap was opened by a key
    /// the picker could not answer, the tap had been dropped, so the digit
    /// also reached the app holding the selection and replaced it — the
    /// original `ORIGINAL` → `34` bug, back for the length of one hop.
    ///
    /// All three ways of ending a picker have that gap, not just the one that
    /// drops the tap.
    @Test("the picker answers once, and a key arriving before it closes is swallowed, not leaked")
    func thePickerAnswersOnce() {
        for ender in [PanelKeyMapTests.enter, PanelKeyMapTests.escape, PanelKeyMapTests.bareZ] {
            let tap = SpyKeyMonitor()
            let controller = makeController(keyInterceptor: tap)
            let picked = Box<Preset>()
            controller.onPickStyle = { picked.value = $0 }

            controller.show(.stylePicker(presets: PanelKeyMapTests.fiveStyles))
            tap.send(ender)
            let answer = picked.value

            // The gap. The tap has to still be here, or the digit lands in the
            // document; and it has to do nothing, or it picks a second style.
            #expect(tap.isInstalled, "\(ender.characters)")
            #expect(tap.send(PanelKeyMapTests.digit(3)) == true, "\(ender.characters)")
            #expect(picked.value == answer, "\(ender.characters)")
        }
    }

    /// A picker with no rows cannot answer anything — but Return and the
    /// arrows still resolved to actions, because reaching the key map counted
    /// as success even when the action found no row to apply itself to. So
    /// "a key the picker cannot answer ends it" never fired for exactly the
    /// keys a picker owns, and the tap swallowed them for as long as the panel
    /// stayed up, which for `stylePicker` is until the user finds Escape.
    /// Nothing stops someone deleting every style, and `chooseStyle` then
    /// shows precisely this.
    ///
    /// Consumed rather than passed on, unlike a key the picker never claims:
    /// the user aimed these at the picker, and a leaked Return submits a form
    /// in whatever happens to be frontmost.
    @Test("an empty picker ends on a key it cannot answer instead of swallowing it forever")
    func anEmptyPickerEndsRatherThanSwallow() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let cancels = Counter()
        controller.onCancel = { cancels.bump() }

        for keystroke in [PanelKeyMapTests.enter, PanelKeyMapTests.arrowDown] {
            controller.show(.stylePicker(presets: []))
            #expect(tap.send(keystroke) == true, "\(keystroke.characters)")
        }

        #expect(cancels.count == 2)
    }

    /// The handler takes the panel down while the keystroke is still being
    /// answered, so nothing may decide the verdict from state read afterwards.
    ///
    /// Production's `onCopy` is `AppDelegate.copyToPasteboard`, which calls
    /// `panel.dismiss()` synchronously: `state` is `nil` before the copy
    /// returns, and dismissing also releases the tap **from inside its own
    /// callback**. If the verdict were read from `state` at that point it
    /// would come back "not consumed" for a ⌘C just performed, and the
    /// frontmost app would run its own Copy over the rewrite — in the one
    /// state where the panel is the user's only copy of it.
    ///
    /// The other ⌘C test passes either way, because its stub only records the
    /// text. A double quieter than production is the case a green suite
    /// cannot catch, so this one dismisses the way the app does.
    @Test("Command-C is still consumed when the copy handler dismisses the panel")
    func commandCIsConsumedWhenTheHandlerDismisses() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let copied = Box<String>()
        controller.onCopy = { [weak controller] text in
            copied.value = text
            controller?.dismiss()
        }

        controller.show(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))

        #expect(tap.send(PanelKeyMapTests.commandC) == true)
        // Positive control: the handler really ran, so the verdict above is
        // about a copy that happened rather than a dead spy.
        #expect(copied.value == "the whole rewrite")
    }

    /// Where ⌘C consumption comes from now.
    ///
    /// It used to come from making the panel key, and a key panel receives
    /// *every* keystroke: ⌘V died in a responder chain with nothing in it, so
    /// the state whose own words are "paste it where you want it" was the one
    /// blocking the paste. Measured against TextEdit — with `makeKey()`, ⌘V
    /// put nothing in the document; without it, the clipboard pasted.
    ///
    /// A tap claims exactly what it acts on, which is the thing a key window
    /// cannot do: ⌘C is taken from the source app, ⌘V is not.
    @Test("a state holding a rewrite takes ⌘C through the tap and leaves ⌘V alone")
    func statesHoldingARewriteConsumeOnlyCommandC() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let copied = Box<String>()
        controller.onCopy = { copied.value = $0 }

        controller.show(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))
        #expect(tap.isInstalled)

        #expect(tap.send(PanelKeyMapTests.commandV) == false)
        #expect(tap.send(PanelKeyMapTests.commandC) == true)
        #expect(copied.value == "the whole rewrite")
    }

    /// Standing down on an unanswerable key belongs to the picker alone.
    ///
    /// The picker is a question, so a key that is not an answer means the user
    /// moved on. A panel holding a rewrite is not a question — it is the only
    /// copy of the user's text, and `autoDismissAfter` is `nil` for exactly
    /// that reason. Carrying the picker's rule into it would let any stray
    /// keystroke anywhere cancel the transaction and throw the rewrite away.
    @Test("a key it cannot answer does not close a panel holding the only copy")
    func anUnclaimedKeyDoesNotEndATerminalPanel() {
        let tap = SpyKeyMonitor()
        let controller = makeController(keyInterceptor: tap)
        let cancels = Counter()
        let copied = Box<String>()
        controller.onCancel = { cancels.bump() }
        controller.onCopy = { copied.value = $0 }

        controller.show(.heldForManualCopy(text: "the whole rewrite", reason: "the window moved"))

        #expect(tap.send(PanelKeyMapTests.bareZ) == false)
        #expect(cancels.count == 0)

        // Positive control: the panel is still up and the tap still working,
        // so the zero above is a verdict rather than a dead spy.
        #expect(tap.send(PanelKeyMapTests.commandC) == true)
        #expect(copied.value == "the whole rewrite")
    }

    /// Announcing is once per kind *per presentation*. What was last said
    /// carries no meaning into the next transaction: a second rewrite opening
    /// on the state the previous one opened on is still news, and without the
    /// reset a screen reader user gets silence exactly where the panel
    /// appeared. The other announce test cannot catch this — it ends on
    /// `.error`, so a stale `announcedKind` would differ from `.capturing`
    /// and it would announce anyway.
    @Test("a new presentation announces itself even when it opens on the last one's state")
    func showResetsTheAnnouncedKind() {
        let surface = SpySurface()
        let controller = makeController(surface: surface)

        controller.show(.capturing)
        controller.show(.capturing)

        #expect(surface.announced == ["Reading selection", "Reading selection"])
    }

    /// A superseded transaction leaves a snapshot held in the coalescer and a
    /// timer pending to release it. The next presentation has to drop that
    /// snapshot: otherwise the timer flushes the *old* rewrite over the new
    /// panel, and in the meantime the panel is holding text from a
    /// transaction that has ended, which root §6 forbids on its own.
    ///
    /// `show()` also used to call `clock.cancel()`, which stopped the same
    /// stale render a second way — and made this test vacuous, because a
    /// timer that cannot fire proves nothing about the coalescer. Either
    /// reset alone was sufficient, so by §1 one was redundant; the cancel
    /// went, because dropping the snapshot is the one with a reason of its
    /// own. `dismiss()` still cancels, where nothing resets the coalescer.
    @Test("a new presentation drops the snapshot the last one was holding")
    func showDropsTheHeldSnapshot() {
        let surface = SpySurface()
        let clock = FakeClock()
        let controller = makeController(surface: surface, clock: clock)

        // Transaction A gets far enough to hold a snapshot back.
        controller.show(.capturing)
        clock.now = clock.start + .seconds(1)
        controller.update(.generating(text: "rendered"))
        clock.now = clock.start + .seconds(1) + .milliseconds(1)
        controller.update(.generating(text: "the superseded rewrite"))
        #expect(clock.hasPending)

        // A is superseded and B begins, with no dismiss in between.
        controller.show(.capturing)
        let rendersAfterShow = surface.presented.count

        // Positive control: the timer is genuinely still armed, so the
        // assertion below is about the coalescer and not about a dead clock.
        #expect(clock.hasPending)
        clock.fire()
        #expect(surface.presented.count == rendersAfterShow)
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
