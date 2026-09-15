import ApplicationServices
import Foundation

/// The frontmost application, as far as `NSWorkspace` is concerned. Reading
/// this needs no Accessibility permission, which is why identity is
/// established before anything that does.
public struct FrontmostApp: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let appVersion: String?

    public init(pid: pid_t, bundleID: String?, appVersion: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.appVersion = appVersion
    }
}

/// Process-wide state that is not reachable through an `AXUIElement`.
///
/// Injected rather than called directly so a test can put the machine in a
/// state it is not actually in — notably "a password field is focused and the
/// process-wide secure-input flag is false", which is what a web or Electron
/// password input looks like and which cannot be staged for real.
public protocol SystemProbing {
    func isSecureEventInputEnabled() -> Bool
    func isAccessibilityTrusted() -> Bool
    func frontmostApp() -> FrontmostApp?
}

/// Element-level accessibility reads. No policy lives behind this protocol;
/// the ordering and the refusals are `SelectionCoordinator`'s job.
public protocol AccessibilityReading: AnyObject {
    func focusedElement(pid: pid_t) -> AXUIElement?
    func role(of element: AXUIElement) -> String?
    func subrole(of element: AXUIElement) -> String?
    func selectedText(of element: AXUIElement) -> String?
    func selectedRange(of element: AXUIElement) -> CFRange?
    func string(of element: AXUIElement, in range: CFRange) -> String?
    func enableManualAccessibility(pid: pid_t)
    func isEditable(_ element: AXUIElement) -> Bool
}

/// The write half. Settability is asked at write time rather than trusted
/// from the snapshot, because a field can go read-only while a rewrite
/// generates and because `snapshot.isEditable` is a permissive hint.
public protocol AccessibilityWriting: AnyObject {
    func isSelectedTextSettable(_ element: AXUIElement) -> Bool
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool
}

/// The synthetic-copy path, behind a protocol so a test can assert that a
/// refusal happened without a keystroke ever being posted.
public protocol ClipboardCapturing: AnyObject {
    func copySelection(pid: pid_t) -> String?
}

/// The synthetic ⌘V, behind a protocol for the same reason.
public protocol KeystrokePosting: AnyObject {
    func postPaste(pid: pid_t)
}

/// The synthetic ⌘C. Injected so the clipboard-borrowing logic either side of
/// it can be driven in a test: posting a real `CGEvent` from a test bundle
/// would type into whatever the user has focused.
public protocol KeystrokeCopying: AnyObject {
    func postCopy(pid: pid_t)
}
