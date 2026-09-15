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
    private let clock: PanelClock
    private let visibleFrame: @MainActor () -> CGRect

    /// Which picker row Return will commit. The view draws the highlight from
    /// this; the key map moves it.
    public private(set) var highlightedStyleIndex = 0

    /// Whether streaming text should keep the newest words in view.
    public private(set) var followsTail = true

    /// The only reference to the installed monitors. See `KeyMonitorHandle`.
    private var armedMonitors: KeyMonitorHandle?
    private var state: PanelState?
    private var coalescer = StreamCoalescer()
    /// Sampled once per presentation. See `screenIsCapturedAtShow`.
    private var anchorScreen: CGRect?

    public init(
        surface: PanelSurface,
        keyMonitor: KeyMonitoring,
        clock: PanelClock,
        visibleFrame: @escaping @MainActor () -> CGRect
    ) {
        self.surface = surface
        self.keyMonitor = keyMonitor
        self.clock = clock
        self.visibleFrame = visibleFrame
    }

    public func show(_ state: PanelState) {
        self.state = state
        anchorScreen = visibleFrame()
        coalescer = StreamCoalescer()
        highlightedStyleIndex = 0
        followsTail = true
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
        surface.hide()
    }

    private func armKeyMonitor() {
        guard armedMonitors == nil else { return }
        armedMonitors = keyMonitor.install { [weak self] keystroke in
            self?.handle(keystroke) ?? false
        }
    }

    /// Returns whether the keystroke was consumed.
    private func handle(_ keystroke: Keystroke) -> Bool {
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

        // Acting on a key is not the same as swallowing it. A global monitor
        // observes and cannot consume, so only a state that took key status
        // may claim the event — and only then does the local monitor swallow
        // it before the frontmost app sees it.
        return state.acceptsKeyWindow
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
    }
}
