import CoreGraphics
import RewriteCore

/// Owns one panel presentation: what it shows, where it sits, and the key
/// monitor that is armed only while it is up.
@MainActor
public final class FloatingPanelController {
    public var onCancel: (@MainActor () -> Void)?
    public var onPickStyle: (@MainActor (Preset) -> Void)?
    public var onCopy: (@MainActor (String) -> Void)?

    private let surface: PanelSurface
    private let keyMonitor: KeyMonitoring
    private let keyInterceptor: KeyMonitoring
    private let clock: PanelClock
    private let visibleFrame: @MainActor () -> CGRect

    /// Which picker row Return will commit. The view draws the highlight from
    /// this; the key map moves it.
    public private(set) var highlightedStyleIndex = 0

    /// Whether streaming text should keep the newest words in view.
    public private(set) var followsTail = true

    /// The only reference to the installed monitors. See `KeyMonitorHandle`.
    private var armedMonitors: KeyMonitorHandle?
    /// The only reference to the installed event tap. See `syncKeyInterceptor`.
    private var armedInterceptor: KeyMonitorHandle?
    /// Every write goes through `didSet`, so no path can move the panel into or
    /// out of the picker without the tap following it.
    private var state: PanelState? {
        didSet { syncKeyInterceptor() }
    }
    private var coalescer = StreamCoalescer()
    /// The last kind spoken to a screen reader, so each state is announced
    /// once. See `render`.
    private var announcedKind: PanelStateKind?
    /// Sampled once per presentation. See `screenIsCapturedAtShow`.
    private var anchorScreen: CGRect?

    public init(
        surface: PanelSurface,
        keyMonitor: KeyMonitoring,
        keyInterceptor: KeyMonitoring,
        clock: PanelClock,
        visibleFrame: @escaping @MainActor () -> CGRect
    ) {
        self.surface = surface
        self.keyMonitor = keyMonitor
        self.keyInterceptor = keyInterceptor
        self.clock = clock
        self.visibleFrame = visibleFrame
    }

    public func show(_ state: PanelState) {
        self.state = state
        anchorScreen = visibleFrame()
        coalescer = StreamCoalescer()
        highlightedStyleIndex = 0
        followsTail = true
        announcedKind = nil
        clock.cancel()
        surface.refreshAppearance()
        armKeyMonitor()
        render(state)
    }

    /// The user took over the scroll position. Following resumes only when
    /// they come back to the bottom themselves.
    public func userScrolled(isAtBottom: Bool) {
        followsTail = isAtBottom
    }

    private func render(_ state: PanelState) {
        let screen = anchorScreen ?? visibleFrame()
        surface.highlightedStyleIndex = highlightedStyleIndex
        let height = surface.contentHeight(for: state, width: PanelGeometry.width(in: screen))
        surface.present(
            state,
            layout: PanelGeometry.layout(contentHeight: height, in: screen),
            followsTail: followsTail,
            acceptsKey: state.acceptsKeyWindow
        )

        // Keyed on the kind, so a streaming burst is announced once rather
        // than per snapshot and an arrow key redrawing the picker is not
        // announced at all. Announcing per render would restart VoiceOver's
        // utterance at token rate and read the same three words forever —
        // the same reason `accessibilityValue` leaves the streaming text out.
        // After `present`, so the panel is up before anything describes it.
        if announcedKind != state.kind {
            announcedKind = state.kind
            surface.announce(state.accessibilityValue)
        }
    }

    /// Moves the panel to a new state without changing the armed monitors.
    ///
    /// Deliberately does not disarm on a terminal state: a result panel sitting
    /// on its auto-dismiss timer should still close when the user hits Escape.
    /// Teardown belongs to `dismiss()` and nowhere else.
    public func update(_ state: PanelState) {
        self.state = state

        if let due = coalescer.accept(state, at: clock.now) {
            clock.cancel()
            render(due)
            return
        }

        // Held back. Something has to come along and release it, or the last
        // snapshot of the rewrite never reaches the screen.
        clock.schedule(after: StreamCoalescer.defaultInterval) { [weak self] in
            guard let self, let held = self.coalescer.flush() else { return }
            self.render(held)
        }
    }

    /// The coordinator's entry point while a stream is running. Goes through
    /// `update(_:)` so there is exactly one throttled path to the screen.
    public func update(from event: RewriteEvent) {
        update(PanelState(event))
    }

    /// Also the mouse path: the `esc Cancel` row is clickable and does not go
    /// through `PanelKeyMap`, so both routes end here.
    public func cancel() {
        onCancel?()
    }

    /// Hands the rewrite the panel is holding to the coordinator to put on the
    /// pasteboard. Silent when the current state has nothing finished to give.
    public func copy() {
        guard let text = state?.copyableText else { return }
        onCopy?(text)
    }

    /// The single exit path. No early return above `disarmKeyMonitor()`, so
    /// every way out of a transaction disarms the monitors.
    public func dismiss() {
        disarmKeyMonitor()
        clock.cancel()
        guard state != nil else { return }
        state = nil
        anchorScreen = nil
        announcedKind = nil
        surface.hide()
    }

    private func armKeyMonitor() {
        guard armedMonitors == nil else { return }
        armedMonitors = keyMonitor.install { [weak self] keystroke in
            self?.handle(keystroke) ?? false
        }
    }

    /// Arms the event tap for the picker and disarms it for everything else.
    ///
    /// The monitors stay up for the whole transaction; this does not. A tap can
    /// delete keystrokes out of every application on the machine, so it exists
    /// only in the state that needs to delete them, and `state.didSet` is what
    /// makes that structural rather than a call at each transition.
    private func syncKeyInterceptor() {
        guard case .stylePicker = state else {
            armedInterceptor = nil
            return
        }
        guard armedInterceptor == nil else { return }
        armedInterceptor = keyInterceptor.install { [weak self] keystroke in
            self?.intercept(keystroke) ?? false
        }
    }

    /// The monitors' answer: whether the keystroke was consumed.
    ///
    /// Acting on a key is not the same as swallowing it. A global monitor
    /// observes and cannot consume at all, so only a state that took key status
    /// may claim the event — and only then does the local monitor swallow it
    /// before the frontmost app sees it.
    private func handle(_ keystroke: Keystroke) -> Bool {
        let acted = perform(keystroke)
        return acted && (state?.acceptsKeyWindow ?? false)
    }

    /// The tap's answer: whether the keystroke was consumed.
    ///
    /// A tap consumes by deleting the event from the stream rather than by
    /// owning the focus, so unlike `handle` it does not have to buy the right
    /// with key status — which is the entire reason the picker can now swallow
    /// its own keys while the source app keeps frontmost and keeps a live
    /// selection. It claims exactly what it acted on, so every other keystroke
    /// the user types passes through untouched.
    private func intercept(_ keystroke: Keystroke) -> Bool {
        if perform(keystroke) { return true }

        // Not an answer to the question the picker is asking, so the user has
        // moved on — most likely to another application, since the picker has
        // no timer and will otherwise sit there. Holding the tap open past
        // that point means swallowing their digits and Return somewhere else
        // entirely. Dropped here rather than waiting for the coordinator to
        // come back through `dismiss()`, because that round trip is more
        // keystrokes. The key itself is not consumed: ending the picker is no
        // reason to eat what the user was actually typing.
        armedInterceptor = nil
        cancel()
        return false
    }

    /// Runs whatever this keystroke means in this state. Returns whether it
    /// meant anything.
    private func perform(_ keystroke: Keystroke) -> Bool {
        guard let state, let action = PanelKeyMap.action(for: keystroke, in: state) else {
            return false
        }

        switch action {
        case .cancel:                   cancel()
        case .copy:                     copy()
        case let .pickStyle(index):     pickStyle(at: index)
        case .commitHighlightedStyle:   pickStyle(at: highlightedStyleIndex)
        case let .moveHighlight(offset): moveHighlight(by: offset)
        }
        return true
    }

    private func moveHighlight(by offset: Int) {
        guard case let .stylePicker(presets) = state, !presets.isEmpty else { return }
        highlightedStyleIndex = min(max(highlightedStyleIndex + offset, 0), presets.count - 1)
        render(.stylePicker(presets: presets))
    }

    /// Also the mouse path: a non-activating panel receives clicks without
    /// activating the app, and a click does not go through `PanelKeyMap`, so
    /// the bounds check lives here rather than there.
    public func pickStyle(at index: Int) {
        guard case let .stylePicker(presets) = state, presets.indices.contains(index) else { return }
        onPickStyle?(presets[index])
    }

    /// Dropping the handle is the removal. Nothing else is needed, and there
    /// is nothing else to forget.
    private func disarmKeyMonitor() {
        armedMonitors = nil
        armedInterceptor = nil
    }
}
