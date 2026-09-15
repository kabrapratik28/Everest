import AppKit

public extension FloatingPanelController {
    /// The controller the app actually runs: a real panel, real `NSEvent`
    /// monitors, a real timer, and the screen under the pointer.
    ///
    /// This factory is the only place the three integration classes are named.
    /// Everything else, including every test, goes through the protocols.
    @MainActor
    static func live() -> FloatingPanelController {
        let surface = NSPanelSurface()
        let controller = FloatingPanelController(
            surface: surface,
            keyMonitor: NSEventKeyMonitor(),
            keyInterceptor: CGEventTapKeyInterceptor(),
            clock: RunLoopPanelClock(),
            // The screen under the pointer, not `NSScreen.main`. `NSScreen.main`
            // is the screen containing the key window, and this app never has
            // one, so it is the wrong question to ask. The choosing is
            // `PanelGeometry.screen(containing:among:)` and is tested; this
            // only supplies the rectangles.
            visibleFrame: {
                let screens = NSScreen.screens
                let mouse = NSEvent.mouseLocation
                guard
                    let frame = PanelGeometry.screen(containing: mouse, among: screens.map(\.frame)),
                    let screen = screens.first(where: { $0.frame == frame })
                else {
                    return .zero
                }
                return screen.visibleFrame
            }
        )
        surface.onCopy = { [weak controller] in controller?.copy() }
        surface.onCancel = { [weak controller] in controller?.cancel() }
        surface.onPickStyle = { [weak controller] index in controller?.pickStyle(at: index) }
        surface.onScroll = { [weak controller] isAtBottom in
            controller?.userScrolled(isAtBottom: isAtBottom)
        }
        return controller
    }
}
