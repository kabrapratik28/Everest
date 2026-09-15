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
    /// Whether the picker has already produced its outcome. See `endPicker`.
    private var pickerIsSpent = false
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
        pickerIsSpent = false
        // No `clock.cancel()` here. A pending flush from the transaction just
        // superseded is harmless once the coalescer is fresh: it finds nothing
        // held and renders nothing, or it releases this presentation's own
        // snapshot a few milliseconds early. Cancelling as well stopped the
        // stale render a second way, which by §1 made one of the two
        // redundant — and it was the cancel, because dropping the snapshot
        // also stops the panel holding a finished transaction's text. It also
        // hid the test: a timer that cannot fire proves nothing about the
        // coalescer. `dismiss()` still cancels, where nothing resets it.
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
        guard state?.needsKeyInterception == true else {
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
        // Captured *before* the action runs, because running it can take the
        // panel down: production's `onCopy` dismisses synchronously, so by the
        // time a ⌘C finishes copying, `state` is nil. Reading key status
        // afterwards then reports "not consumed" for a key just acted on, and
        // the frontmost app runs its own Copy over the rewrite we had put on
        // the clipboard — in `heldForManualCopy`, the user's only copy of it.
        // The verdict belongs to the state the keystroke was dispatched
        // against, not to whatever `state` became along the way.
        guard let dispatchedAgainst = state,
              let action = PanelKeyMap.action(for: keystroke, in: dispatchedAgainst)
        else { return false }

        // Fail closed. These monitors observe and cannot consume, so in a
        // state that needs a key taken from the app underneath they are only
        // safe to act on while the tap is there to take it. Without one, a
        // digit picks a style *and* lands in the document, and a ⌘C we
        // honour is overwritten by the source app's own Copy a moment later
        // — with `onCopy` having already dismissed the panel and the only
        // copy of the rewrite gone with it. Half-working while editing the
        // user's text is worse than visibly doing nothing.
        //
        // Escape is the one exception: a leaked Escape is harmless, which is
        // why Return was never bound, and without it the keyboard has no way
        // out of a panel that has stopped answering.
        if dispatchedAgainst.needsKeyInterception,
           armedInterceptor?.isActive != true,
           action != .cancel {
            return false
        }

        let acted = run(action)
        return acted && dispatchedAgainst.acceptsKeyWindow
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
        guard let current = state else { return false }
        guard let action = PanelKeyMap.action(for: keystroke, in: current) else {
            // Standing down here belongs to the picker alone. A panel holding
            // a rewrite is not a question — it is the user's only copy, and
            // `autoDismissAfter` is `nil` for that reason, so letting a stray
            // keystroke anywhere cancel it would throw the rewrite away.
            guard case .stylePicker = current else { return false }

            // Nothing the picker could answer, so the user has moved on —
            // most likely to another application, since the picker has no
            // timer and will otherwise sit there. Passed on rather than
            // eaten: ending the picker is no reason to swallow the keystroke
            // the user was actually typing.
            //
            // The tap is deliberately *not* dropped here. It was, and that
            // reopened the original bug: `state` stays `.stylePicker` until
            // the coordinator comes back through `dismiss()`, so for one actor
            // hop the picker keys still resolve — and with the tap gone a
            // digit reached the app holding the selection and replaced it.
            // `state.didSet` and `dismiss()` already bound the tap's life;
            // `pickerIsSpent` makes the interval inert rather than trying to
            // win a race against it.
            endPicker()
            return false
        }
        guard run(action) else {
            // A key the picker *owns* with no row to apply it to: an empty
            // style list, or a picker already answered. Unlike a key it never
            // claims, this one was aimed at the panel, so it is swallowed
            // rather than handed on — a leaked Return submits a form. It
            // still cannot be answered, so the picker ends.
            endPicker()
            return true
        }
        return true
    }

    /// The picker has produced its one outcome.
    ///
    /// Idempotent, so a run of keys arriving in the same gap is one
    /// cancellation at the coordinator rather than one per keystroke.
    private func endPicker() {
        guard !pickerIsSpent else { return }
        pickerIsSpent = true
        cancel()
    }

    /// Returns whether the action found anything to act on. Reaching the key
    /// map is not enough: Return and the arrows resolve in a picker with no
    /// rows at all, and reporting those no-ops as success is what let an empty
    /// picker swallow them instead of standing down.
    private func run(_ action: PanelKeyAction) -> Bool {
        switch action {
        // Escape ends the picker too, and has exactly the same gap before the
        // coordinator can dismiss. Harmless in the states that are not a
        // picker, where the flag is never read again.
        case .cancel:
            pickerIsSpent = true
            cancel()
            return true
        // The key map only offers this where `copyableText` is non-nil.
        case .copy:
            copy()
            return true
        case let .pickStyle(index):
            return pickStyle(at: index)
        case .commitHighlightedStyle:
            return pickStyle(at: highlightedStyleIndex)
        case let .moveHighlight(offset):
            return moveHighlight(by: offset)
        }
    }

    private func moveHighlight(by offset: Int) -> Bool {
        guard case let .stylePicker(presets) = state, !presets.isEmpty else { return false }
        highlightedStyleIndex = min(max(highlightedStyleIndex + offset, 0), presets.count - 1)
        render(.stylePicker(presets: presets))
        return true
    }

    /// Also the mouse path: a non-activating panel receives clicks without
    /// activating the app, and a click does not go through `PanelKeyMap`, so
    /// the bounds check lives here rather than there.
    /// Returns whether there was such a row to pick.
    @discardableResult
    public func pickStyle(at index: Int) -> Bool {
        guard !pickerIsSpent,
              case let .stylePicker(presets) = state,
              presets.indices.contains(index)
        else { return false }
        pickerIsSpent = true
        onPickStyle?(presets[index])
        return true
    }

    /// Dropping the handle is the removal. Nothing else is needed, and there
    /// is nothing else to forget.
    private func disarmKeyMonitor() {
        armedMonitors = nil
        armedInterceptor = nil
    }
}
