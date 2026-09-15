import AppKit

/// The real `KeyMonitoring`: a global `NSEvent` monitor and a local one.
///
/// Integration only. `FloatingPanelController` decides *when* the monitors are
/// armed and the tests assert that balance against a spy; this class only knows
/// how to turn that decision into `NSEvent` calls.
@MainActor
public final class NSEventKeyMonitor: KeyMonitoring {
    public init() {}

    public func install(_ handler: @escaping @MainActor (Keystroke) -> Bool) -> KeyMonitorHandle {
        var installed: [Any] = []

        // Fires while another application is frontmost, which is the normal
        // case for this app. An observer: it cannot consume the event, so its
        // return value is discarded.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            // `Keystroke` is Sendable and `NSEvent` is not, so the event is
            // reduced to a value *before* crossing into the isolated closure.
            let keystroke = Keystroke(event)
            MainActor.assumeIsolated { _ = handler(keystroke) }
        }) {
            installed.append(global)
        }

        // Global monitors never see our own process's events. Without this one
        // Escape is dead in exactly the case where the user has Settings open
        // and is looking straight at the app. This one *can* consume: returning
        // nil swallows the event, which is how ⌘C is kept from also reaching
        // the frontmost app in a terminal state.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let keystroke = Keystroke(event)
            let consumed = MainActor.assumeIsolated { handler(keystroke) }
            return consumed ? nil : event
        }) {
            installed.append(local)
        }

        // The returned handle is the only thing keeping these alive.
        return KeyMonitorHandle {
            for token in installed { NSEvent.removeMonitor(token) }
        }
    }
}
