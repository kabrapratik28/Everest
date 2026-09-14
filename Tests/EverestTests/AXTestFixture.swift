import AppKit
import ApplicationServices
import XCTest

@testable import Everest

/// A real accessibility element, built inside the test process.
///
/// These guards are about what the accessibility API actually reports, not
/// about what we believe it reports. An `NSSecureTextField` announcing role
/// `AXTextField` with subrole `AXSecureTextField` is the whole reason
/// `isSecureElement` checks two slots, and a mock that returned a canned
/// subrole would test the mock. So the fixture builds genuine AppKit views and
/// reads them back through `AXUIElementCreateApplication(getpid())`.
///
/// Same-process accessibility queries work and are fast, about one
/// millisecond, measured on macOS 26. They do not deadlock against the main
/// thread the way cross-process calls to a blocked app would.
///
/// Two deliberate properties keep this usable on a machine somebody is
/// working on:
///
/// - The window is positioned far off screen and is never made key, and the
///   app is never activated. Nothing appears, and focus is not stolen.
/// - Nothing here depends on the test process being frontmost. Elements are
///   reached by walking the application element's window list, not by asking
///   for system focus, so the result does not change when the developer
///   clicks somewhere else mid-run.
@MainActor
final class AXTestFixture {

    /// Far enough off screen that the window is never visible, while still
    /// being a real ordered-in window the accessibility tree reports.
    private static let offScreen = NSRect(x: -30_000, y: -30_000, width: 480, height: 200)

    let window: NSWindow
    private(set) var textView: NSTextView?
    private(set) var secureField: NSSecureTextField?

    enum Kind { case textView(String), secureField(String) }

    init(_ kind: Kind) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: Self.offScreen,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "EverestTestFixture"

        switch kind {
        case .textView(let body):
            let view = NSTextView(frame: NSRect(x: 10, y: 10, width: 460, height: 180))
            view.isEditable = true
            view.isRichText = false
            view.string = body
            window.contentView?.addSubview(view)
            textView = view
        case .secureField(let body):
            let field = NSSecureTextField(frame: NSRect(x: 10, y: 80, width: 460, height: 24))
            field.stringValue = body
            window.contentView?.addSubview(field)
            secureField = field
        }

        // orderFront, never makeKeyAndOrderFront, and no NSApp.activate. The
        // window has to exist for the window server to describe it; it does
        // not have to be key, and stealing key would disturb the user.
        window.orderFront(nil)
    }

    func tearDown() {
        window.orderOut(nil)
        window.close()
    }

    /// The accessibility element for the view this fixture created.
    ///
    /// Polls rather than sleeping: window registration with the accessibility
    /// server is asynchronous, so the first read can legitimately come back
    /// empty. The loop is bounded and the caller fails the test if it expires,
    /// so a slow machine costs milliseconds and a broken one fails loudly
    /// instead of hanging.
    func element(timeout: TimeInterval = 5) -> AXUIElement? {
        let wanted: Set<String> = textView != nil
            ? ["AXTextArea"]
            : ["AXTextField", "AXSecureTextField"]

        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1.0)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            for window in windows(of: app) where title(of: window) == "EverestTestFixture" {
                if let found = firstDescendant(of: window, roleIn: wanted, depth: 0) {
                    return found
                }
            }
            // Bounded run-loop turn. The window server needs a cycle to
            // publish the new window; this is not a fixed settle time,
            // because the loop exits the instant the element appears.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    // MARK: - Tree walking

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func firstDescendant(
        of element: AXUIElement,
        roleIn roles: Set<String>,
        depth: Int
    ) -> AXUIElement? {
        guard depth < 12 else { return nil }

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String
        {
            if roles.contains(role) { return element }
            // A secure field reports role AXTextField and announces itself
            // only in the subrole, which is exactly the case this fixture
            // exists to reproduce.
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
               let subrole = subroleValue as? String,
               roles.contains(subrole)
            {
                return element
            }
        }

        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
              let children = childValue as? [AXUIElement]
        else { return nil }

        for child in children {
            if let found = firstDescendant(of: child, roleIn: roles, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Selection control

    /// Sets the selected range through the accessibility API, the same way a
    /// real app's selection would be observed.
    @discardableResult
    func select(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}

// MARK: - Shared helpers

/// A pasteboard nobody else is using. Every test in this bundle uses one of
/// these. `NSPasteboard.general` is the developer's real clipboard and must
/// never be touched by a test run.
@MainActor
func makePrivatePasteboard(_ label: String = #function) -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.everest.tests.\(label).\(UUID().uuidString)"))
}

/// A stub that records whether the clipboard fallback was reached.
///
/// Two jobs. It proves a refusal happened *before* any text was read, which is
/// the actual claim being tested. And it prevents the real implementation from
/// posting a synthetic Command C into whatever application the developer has
/// in front, which a test must never do.
@MainActor
final class RecordingClipboardAdapter: ClipboardSelectionAdapter {
    private(set) var copyCallCount = 0
    var stubbedText: String?

    override func copySelection() -> String? {
        copyCallCount += 1
        return stubbedText
    }
}

extension TargetSnapshot {
    /// A snapshot whose pid belongs to no running process, so the frontmost
    /// check in `TargetValidator` is guaranteed to fail. Used to drive the
    /// revalidation guard without needing to control which app is in front.
    @MainActor
    static func withDeadPid(text: String, element: AXUIElement) -> TargetSnapshot {
        TargetSnapshot(
            pid: pid_t.max - 1,
            bundleID: "com.everest.tests.nonexistent",
            appVersion: "0",
            element: element,
            text: text,
            range: CFRange(location: 0, length: (text as NSString).length),
            role: "AXTextArea",
            isEditable: true,
            capturedAt: ContinuousClock.now
        )
    }
}
