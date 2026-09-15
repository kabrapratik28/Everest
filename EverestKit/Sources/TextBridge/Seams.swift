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

    /// How many characters the element holds, which is what decides whether a
    /// zero-length selected range is an answer about the user's selection or
    /// an answer about an element the selection was never in. `nil` when the
    /// element does not implement the attribute, which is the same state of
    /// knowledge as zero.
    func characterCount(of element: AXUIElement) -> Int?

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

/// What rung 9 came back with. Three states rather than an optional, because
/// "⌘C produced nothing" and "the clipboard could not be borrowed" have
/// different causes and different remedies, and collapsing them told a user
/// whose clipboard held a screenshot that this app's text cannot be read.
public enum ClipboardCapture: Equatable, Sendable {
    case captured(String)

    /// ⌘C was posted and the target wrote nothing.
    case nothingCopied

    /// The borrow was refused, so ⌘C was never posted and nothing was
    /// disturbed. Not split into too-large and already-borrowed: `Fidelity`
    /// keeps those apart where it matters, and capture blocks the main
    /// thread, so in production only the first can reach a user.
    case unavailable
}

/// The synthetic-copy path, behind a protocol so a test can assert that a
/// refusal happened without a keystroke ever being posted.
public protocol ClipboardCapturing: AnyObject {
    func copySelection(pid: pid_t) -> ClipboardCapture
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
