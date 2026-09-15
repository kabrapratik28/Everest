import AppKit
import CoreGraphics

/// The `KeyMonitoring` that can actually *take* a key away from the frontmost
/// application.
///
/// Integration only, like `NSEventKeyMonitor`. `FloatingPanelController`
/// decides when this is armed and which keystrokes it claims; this class only
/// knows how to turn that decision into a `CGEventTap`.
///
/// A tap at `.cgSessionEventTap` sits ahead of the window server's dispatch to
/// any application, so returning `nil` deletes the event from the stream
/// entirely — the source app never sees it, and neither does our own
/// `NSEventKeyMonitor`, so a claimed key is acted on exactly once. Unlike a key
/// window, none of this costs the source app frontmost, which is what lets the
/// picker swallow its own keys while the selection stays live.
@MainActor
public final class CGEventTapKeyInterceptor: KeyMonitoring {
    public init() {}

    /// Everything the C callback needs, reached through `userInfo` because a
    /// `CGEventTapCallBack` is a bare function pointer and can capture nothing.
    /// Retained for exactly as long as the tap, and released by the handle.
    private final class Context {
        let handler: @MainActor (Keystroke) -> Bool
        var tap: CFMachPort?

        init(handler: @escaping @MainActor (Keystroke) -> Bool) { self.handler = handler }
    }

    public func install(_ handler: @escaping @MainActor (Keystroke) -> Bool) -> KeyMonitorHandle {
        let context = Unmanaged.passRetained(Context(handler: handler)).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // `.defaultTap`, not `.listenOnly`: a listen-only tap is the same
            // observer the global monitor already is, and the whole point here
            // is to be able to return nil.
            options: .defaultTap,
            // Key-down only, matching the local monitor. Text is inserted on
            // key-down, so a stray key-up reaching the app below changes
            // nothing, and tracking which ups to match would be state to keep
            // right for no behaviour.
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()

                // The system switches a tap off if its callback is ever slow,
                // and says nothing: the picker would simply stop responding to
                // the keyboard from then on, for the rest of the session.
                if type == .tapDisabledByTimeout {
                    if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return nil
                }

                // Through `NSEvent` so the reduction to a `Keystroke` is the
                // one adapter the monitors already use, rather than a second
                // parsing of key codes and flags that could drift from it.
                guard let native = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                let keystroke = Keystroke(native)
                // Held strongly for the length of the call. The handler is what
                // moves the panel off the picker, and moving off the picker is
                // what releases this tap — so a handler that did it
                // synchronously would free the closure it is still running.
                let handler = context.handler
                // The source is on the main run loop, so this is already the
                // main thread.
                let consumed = MainActor.assumeIsolated { handler(keystroke) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            // Accessibility was revoked. The picker still works through the
            // monitors; it just cannot keep its keys from the app underneath.
            Unmanaged<Context>.fromOpaque(context).release()
            return KeyMonitorHandle {}
        }

        Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // The returned handle is the only thing keeping the tap alive.
        return KeyMonitorHandle {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            Unmanaged<Context>.fromOpaque(context).release()
        }
    }
}
