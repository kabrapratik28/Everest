import AppKit
import SwiftUI
import RewriteCore

// MARK: - The view's half of the state

/// The single object the SwiftUI view observes.
///
/// The controller writes, the view reads, and the view's two user actions
/// (Cancel, pick a style) come back out through closures installed here rather
/// than through a reference to the controller. That keeps `RewriteView` and
/// `StylePickerView` free of any knowledge that AppKit exists, which is what
/// lets them be rendered in a preview or a debug harness with no panel at all.
@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState = .capturing
    @Published var appearance: PanelAppearance = .default
    /// Which row the style picker has highlighted. Lives here, not in
    /// `@FocusState`, because the arrow keys arrive from an event monitor and
    /// there is no first responder in this window to focus. See
    /// `StylePickerView`'s doc comment.
    @Published var selectedStyleIndex: Int = 0

    var onCancel: (() -> Void)?
    var onPick: ((Preset) -> Void)?

    func cancel() { onCancel?() }
    func pickStyle(_ preset: Preset) { onPick?(preset) }
}

// MARK: - Key monitors

/// The two `NSEvent` monitors, owned as one object whose lifetime *is* their
/// lifetime.
///
/// This exists as a separate class for one reason: so that dropping the
/// reference removes the monitors. A global key-down monitor sees every
/// keystroke the user types in every application, forever, until it is removed.
/// That is the most sensitive thing this app ever touches and the guard against
/// leaking it cannot be "remember to call the remove function on all four exit
/// paths". Here, ARC is the guard. `stopKeyMonitor()` sets the reference to
/// `nil`; if the controller is ever deallocated with a transaction on screen,
/// the same `deinit` still runs. There is no path that keeps the monitors
/// installed and loses the handle to them.
///
/// Two monitors, because they cover disjoint cases and neither is optional:
///
/// - **Global** fires while *another* application is frontmost, which is the
///   normal case for this app. It cannot consume the event: the keystroke is
///   also delivered to whatever app is focused. That is a real limitation, not
///   an oversight, and it is why the coordinator should have captured the
///   selection before a picker is ever shown.
/// - **Local** fires when our own process is frontmost, which happens when the
///   user has Settings open or clicked the status item. Global monitors do not
///   see your own app's events, so without this one Escape would silently stop
///   working in exactly the situation where the user is most likely to be
///   looking at the app.
private final class KeyMonitorPair {
    private var tokens: [Any] = []

    init(owner: FloatingPanelController) {
        // `[weak owner]` and not `[weak self]`: the closures must not capture
        // this object, or the monitors would keep it alive and the deinit that
        // removes them could never run.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak owner] event in
            MainActor.assumeIsolated {
                guard let owner else { return }
                _ = owner.handleKeyDown(event)
            }
        }) {
            tokens.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak owner] event -> NSEvent? in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let owner else { return false }
                return owner.handleKeyDown(event)
            }
            // Returning nil swallows the event. Only done for keys we actually
            // acted on, so ordinary typing in our own Settings window is
            // untouched.
            return handled ? nil : event
        }) {
            tokens.append(local)
        }
    }

    deinit {
        let tokens = self.tokens
        MainActor.assumeIsolated {
            for token in tokens { NSEvent.removeMonitor(token) }
        }
    }
}

// MARK: - Controller

/// Owns the floating panel: its window, its geometry, its key monitors, and the
/// rate at which streaming updates are allowed to reach the screen.
///
/// Read `Overlay/AGENTS.md` before changing the window configuration or the
/// event monitors. Several things in here look like they could be simpler and
/// cannot.
@MainActor
final class FloatingPanelController {

    // MARK: Callbacks

    /// Escape, the Cancel button, or a dismissed picker. The controller does
    /// not dismiss itself in response: cancelling is the coordinator's
    /// decision, it may need to tear down a running generation first, and it
    /// calls `dismiss()` when it is ready.
    var onCancel: (() -> Void)?

    /// A style was chosen, by digit, by Return, or by click.
    var onPickStyle: ((Preset) -> Void)?

    // MARK: Stored state

    private let model = PanelModel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<RewriteView>?
    private var scrollView: NSScrollView?

    private var keyMonitors: KeyMonitorPair?

    /// The screen the panel was placed on. Held for the whole presentation so
    /// that a panel growing as text streams in does not hop to another display
    /// because the user moved the mouse.
    private var anchorScreen: NSScreen?

    // MARK: Throttle state

    /// Roughly one display frame. See `update(_:)`.
    private static let frameInterval: Duration = .milliseconds(16)

    private var pendingState: PanelState?
    private var flushTimer: Timer?
    private var lastRenderedAt: ContinuousClock.Instant?

    init() {}

    // MARK: - Public API

    /// Puts the panel on screen showing `state`, anchors it to the screen the
    /// mouse is on, and arms the key monitors.
    ///
    /// Safe to call while already visible: the panel re-anchors, which is the
    /// right behavior when the user starts a second rewrite on another display.
    func show(_ state: PanelState) {
        // Sampled per presentation rather than observed. See PanelAppearance.
        model.appearance = .current
        anchorScreen = screenUnderMouse()

        let panel = makePanelIfNeeded()
        renderImmediately(state)
        panel.orderFrontRegardless()

        startKeyMonitor()
    }

    /// Pushes a new state into a panel that is already up.
    ///
    /// **Streaming states are coalesced to about one display frame.** A 4B model
    /// on an M4 emits tokens faster than 60 Hz, and every `RewriteEvent`
    /// carries a full cumulative snapshot of the output so far, so rendering
    /// each one means re-laying out an entire growing paragraph dozens of times
    /// per second for no visible benefit. Dropping an intermediate snapshot
    /// costs nothing precisely because they are snapshots and not deltas: the
    /// next one is a superset. The throttle lives here and not in the view so
    /// that it applies once, at the boundary, instead of being re-derived by
    /// every view that might want to show progress.
    ///
    /// Anything that is not streaming renders immediately and cancels a pending
    /// flush. A terminal state must never sit behind a 16 ms timer holding a
    /// stale spinner, and more importantly must never be *overwritten* by a
    /// queued older snapshot.
    func update(_ state: PanelState) {
        // `isVisible` and not `panel != nil`: the panel object is kept alive
        // across dismissals and reused, so a nil check would pass for a panel
        // that has been ordered out and leave the transaction with no UI at
        // all. Silently dropping the state is worse than an unanticipated show.
        guard panel?.isVisible == true else {
            show(state)
            return
        }

        guard state.isStreaming else {
            cancelPendingFlush()
            renderImmediately(state)
            return
        }

        let now = ContinuousClock.now
        guard let last = lastRenderedAt else {
            renderImmediately(state)
            return
        }

        let elapsed = last.duration(to: now)
        if elapsed >= Self.frameInterval {
            cancelPendingFlush()
            renderImmediately(state)
        } else {
            // Newest snapshot wins; the one it replaces was a prefix of it.
            pendingState = state
            scheduleFlush(after: Self.frameInterval - elapsed)
        }
    }

    /// Takes the panel down and disarms everything.
    ///
    /// The monitor teardown is the first statement and this function has no
    /// early return, on purpose. Every exit from a transaction, successful or
    /// not, funnels through here.
    func dismiss() {
        stopKeyMonitor()
        cancelPendingFlush()

        panel?.orderOut(nil)
        anchorScreen = nil
        lastRenderedAt = nil
        model.selectedStyleIndex = 0
    }

    /// Convenience bridge for `RewriteCore`'s engine events, so the coordinator
    /// does not have to restate the mapping.
    ///
    /// `.finished` maps to `generating` rather than to a terminal state because
    /// the engine finishing is not the end of the transaction: validation and
    /// replacement come after it, and only the coordinator knows whether the
    /// result ends in `success`, `readOnly` or `targetChanged`.
    func update(from event: RewriteEvent) {
        switch event {
        case .preparing(let progress):
            update(.preparing(progress: progress))
        case .outputSnapshot(let text):
            update(.generating(text: text))
        case .finished(let text):
            update(.generating(text: text))
        }
    }

    // MARK: - Key handling

    /// Returns `true` when the event was acted on. Only the local monitor can
    /// act on that return value; a global monitor is an observer and the
    /// keystroke reaches the focused app either way.
    fileprivate func handleKeyDown(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true else { return false }

        let code = event.keyCode

        // Escape, in every state, including terminal ones: a success or error
        // panel waiting on its auto-dismiss timer should still close the moment
        // the user asks it to.
        if code == Keys.escape, !event.modifierFlags.contains(.command) {
            onCancel?()
            return true
        }

        guard case .stylePicker(let presets) = model.state, !presets.isEmpty else {
            return false
        }

        switch code {
        case Keys.downArrow:
            moveSelection(by: 1, count: presets.count)
            return true
        case Keys.upArrow:
            moveSelection(by: -1, count: presets.count)
            return true
        case Keys.return_, Keys.keypadEnter:
            guard plainKeystroke(event) else { return false }
            choose(presets[clamped(model.selectedStyleIndex, count: presets.count)])
            return true
        default:
            // Digits are the advertised fast path. Guarded on modifiers so that
            // ⌘3 in the app underneath is not stolen and turned into a style.
            guard plainKeystroke(event),
                  let digit = digit(from: event),
                  digit >= 1,
                  digit <= min(5, presets.count)
            else { return false }
            choose(presets[digit - 1])
            return true
        }
    }

    private func moveSelection(by delta: Int, count: Int) {
        let next = clamped(model.selectedStyleIndex, count: count) + delta
        model.selectedStyleIndex = clamped(next, count: count)
    }

    private func choose(_ preset: Preset) {
        onPickStyle?(preset)
    }

    private func isPicker(_ state: PanelState) -> Bool {
        if case .stylePicker = state { return true }
        return false
    }

    private func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// True when no modifier that changes a key's meaning is held. `.function`
    /// and `.numericPad` are set by the arrow keys and the keypad and are not
    /// modifiers in that sense; `.capsLock` is not either.
    private func plainKeystroke(_ event: NSEvent) -> Bool {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
            .isEmpty
    }

    private func digit(from event: NSEvent) -> Int? {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let value = Int(characters)
        else { return nil }
        return value
    }

    private enum Keys {
        static let escape: UInt16 = 53
        static let return_: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
    }

    // MARK: - Monitor lifecycle

    /// Idempotent. Arming twice would install four monitors and Escape would
    /// fire `onCancel` twice.
    private func startKeyMonitor() {
        guard keyMonitors == nil else { return }
        keyMonitors = KeyMonitorPair(owner: self)
    }

    /// The only way the monitors come down, and it cannot fail: releasing the
    /// object removes them.
    private func stopKeyMonitor() {
        keyMonitors = nil
    }

    // MARK: - Throttle plumbing

    private func scheduleFlush(after delay: Duration) {
        guard flushTimer == nil else { return }

        let seconds = max(Self.timeInterval(delay), 0.001)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushPending()
            }
        }
        // `.common` and not the default mode: a default-mode timer stops firing
        // while the user holds a scroll gesture or a menu open, which would
        // freeze the streaming text mid-rewrite.
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func flushPending() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard let pending = pendingState else { return }
        pendingState = nil
        renderImmediately(pending)
    }

    private func cancelPendingFlush() {
        flushTimer?.invalidate()
        flushTimer = nil
        pendingState = nil
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    // MARK: - Rendering and geometry

    private func renderImmediately(_ state: PanelState) {
        // Reset the highlight only when *entering* the picker. Resetting on
        // every picker render would fight the arrow keys, which move the index
        // without pushing a new state.
        if isPicker(state), !isPicker(model.state) {
            model.selectedStyleIndex = 0
        }

        model.state = state
        lastRenderedAt = ContinuousClock.now
        resizeAndPosition()
    }

    /// Measures the SwiftUI content at the fixed panel width, clamps the height
    /// to 40% of the anchor screen, and pins the result to the bottom centre.
    ///
    /// The window origin is recomputed from the *bottom* edge every time, so a
    /// panel that grows as text streams in grows upward and its bottom edge
    /// never moves. Anchoring the top instead makes the whole panel crawl down
    /// the screen during a rewrite.
    private func resizeAndPosition() {
        guard let panel, let hostingView else { return }
        guard let screen = anchorScreen ?? screenUnderMouse() else { return }

        let visible = screen.visibleFrame
        let cap = (visible.height * PanelMetrics.maxHeightFraction).rounded(.down)

        // Give the hosting view its final width before measuring: the height of
        // wrapped text is a function of the width it is laid out at, and an
        // unconstrained measurement reports the single-line height of a
        // paragraph that will actually wrap to eight lines.
        hostingView.setFrameSize(NSSize(width: PanelMetrics.width, height: hostingView.frame.height))
        hostingView.layoutSubtreeIfNeeded()

        let fitting = hostingView.fittingSize.height
        let intrinsic = hostingView.intrinsicContentSize.height
        let natural = max(fitting, intrinsic == NSView.noIntrinsicMetric ? 0 : intrinsic)

        let height = min(max(natural.rounded(.up), PanelMetrics.minHeight), max(cap, PanelMetrics.minHeight))

        let origin = NSPoint(
            x: (visible.midX - PanelMetrics.width / 2).rounded(),
            y: (visible.minY + PanelMetrics.bottomMargin).rounded()
        )
        let frame = NSRect(origin: origin, size: NSSize(width: PanelMetrics.width, height: height))

        if panel.frame != frame {
            // `animate: false` always. The panel is on screen for a couple of
            // seconds and an animated resize on every streamed frame would be
            // both ugly and, under Reduce Motion, wrong.
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    /// The screen the pointer is on, which is the one the user is looking at.
    /// `NSScreen.main` is the screen with the key window, and this app
    /// deliberately never has one.
    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Window construction

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.minHeight),
            // `.nonactivatingPanel` is the entire reason this is an NSPanel and
            // not an NSWindow. Without it, showing the panel activates this app,
            // the frontmost app resigns active, and the selection we are about
            // to rewrite is deselected before we can write to it. `.borderless`
            // removes the titlebar; a titled panel would also let the window
            // become key.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        // Follow the user across Spaces and sit above a fullscreen app instead
        // of forcing a Space switch when the hotkey is pressed.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // Transparent window, so the SwiftUI material in PanelChrome is what the
        // user sees and the rounded corners are not sitting on a grey rectangle.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        // Keep it out of ⌘` and out of window lists. It is a HUD, not a window.
        panel.isExcludedFromWindowsMenu = true

        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onPick = { [weak self] preset in self?.onPickStyle?(preset) }

        let container = NSView(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        container.wantsLayer = true
        container.layer?.cornerRadius = PanelMetrics.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let chrome = NSHostingView(rootView: PanelChrome(model: model))
        chrome.frame = container.bounds
        chrome.autoresizingMask = [.width, .height]
        container.addSubview(chrome)

        let hostingView = NSHostingView(rootView: RewriteView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay scrollers take no layout width, which is what keeps the
        // document view exactly `PanelMetrics.width` wide and the measured
        // height honest.
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = hostingView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // Width is pinned to a constant rather than to the clip view so the
            // constraint set stays satisfiable during the window resize that
            // this same measurement is about to cause.
            hostingView.widthAnchor.constraint(equalToConstant: PanelMetrics.width),
        ])

        panel.contentView = container

        self.panel = panel
        self.hostingView = hostingView
        self.scrollView = scrollView
        return panel
    }
}
