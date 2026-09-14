import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "selection.ax"
)

/// Thin, side-effect-free wrappers over the C accessibility API.
///
/// This type holds no state and makes no policy decisions. It exists so that
/// every `AXUIElementCopyAttributeValue` in the app goes through one place that
/// gets the CoreFoundation bridging right, applies a messaging timeout, and
/// never throws. Policy (what order to try things in, what to refuse) lives in
/// `SelectionCoordinator`; verification lives in `TargetValidator`.
///
/// `@MainActor` because accessibility calls are synchronous cross-process IPC
/// and the rest of this subsystem drives AppKit. Isolating to the main actor
/// also serialises them for free, which matters because the accessibility API
/// is not documented to be thread safe.
@MainActor
enum AXSelectionAdapter {

    // MARK: - Constants

    /// Undocumented attribute that asks a Chromium or Electron process to build
    /// its accessibility tree. Not in the SDK, so it is spelled out here.
    static let manualAccessibilityAttribute = "AXManualAccessibility"

    /// `kAXSecureTextFieldSubrole` is `"AXSecureTextField"`. Apps report it in
    /// either the role or the subrole slot depending on the toolkit, so both are
    /// checked against this set.
    static let secureRoleNames: Set<String> = [kAXSecureTextFieldSubrole]

    /// Roles that usually accept typing. A weak hint only, used to avoid
    /// under-reporting editability for elements that hide their settability.
    static let editableRoleNames: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Per-element timeout for accessibility IPC, in seconds.
    ///
    /// The default is several seconds. An unresponsive or accessibility-hostile
    /// app would otherwise freeze the main thread for that long on every failed
    /// attribute read, and the capture chain makes several reads. A third of a
    /// second is far above the few milliseconds a healthy app needs and far
    /// below the point where a person notices a hang.
    static let messagingTimeout: Float = 0.35

    // MARK: - Process level checks

    /// True when any process on the system has turned on secure keyboard entry.
    ///
    /// This is a global flag, not a per-field one. Password managers, the login
    /// window, and Terminal's "Secure Keyboard Entry" all set it. While it is
    /// on, synthetic key events are not delivered, so the clipboard path could
    /// not work anyway. Refusing on the flag alone is both the safe answer and
    /// the honest one.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Element lookup

    static func systemWideElement() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// The focused element **belonging to `pid`**, or nil.
    ///
    /// Two lookups, and both are needed.
    ///
    /// The system-wide element is asked first because it reflects real keyboard
    /// focus, including focus that has landed in a panel or a helper process.
    /// It is not reliable on its own: querying `AXFocusedUIElement` on the
    /// system-wide element returns `kAXErrorCannotComplete` against some
    /// frontmost apps even when the identical query against that app's own
    /// element succeeds immediately. Measured against TextEdit on macOS 26.
    /// Treating that error as "nothing is selected" would make Everest look
    /// broken in ordinary apps.
    ///
    /// The result is then required to belong to `pid`. This is a safety check,
    /// not a tidiness one: the exclusion list and the bundle identifier were
    /// evaluated against the frontmost process, so reading an element owned by
    /// some other process would read text that was never checked against the
    /// user's list of apps Everest must keep out of. If system-wide focus has
    /// wandered elsewhere, the app's own focused element is used instead.
    ///
    /// `nil` means this app answered nothing, which is the normal state for a
    /// Chromium or Electron process that has not been asked to build its
    /// accessibility tree yet.
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        if let element = copyElement(systemWideElement(), kAXFocusedUIElementAttribute),
           self.pid(of: element) == pid
        {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            return element
        }
        guard let element = copyElement(
            applicationElement(pid: pid), kAXFocusedUIElementAttribute)
        else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    // MARK: - Attribute reads

    static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: the type ID was just checked. A conditional cast to a
        // CoreFoundation type always succeeds and would hide a wrong type.
        return (value as! AXUIElement)
    }

    /// Reads an `AXValue` of kind `cfRange`.
    ///
    /// `nil` means the app does not report a range at all, which is a different
    /// fact from "the range is empty" and is why the caller must distinguish
    /// them. See the capture chain in `SelectionCoordinator`.
    static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copyValue(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// `AXStringForRange`, the parameterized read used when an app reports a
    /// selection range but returns nothing for `AXSelectedText`.
    static func stringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &result
        )
        guard error == .success else { return nil }
        return result as? String
    }

    // MARK: - Attribute writes

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
    }

    /// Asks a Chromium or Electron process to build an accessibility tree.
    ///
    /// Chromium keeps its tree switched off until something asks for it, because
    /// building and maintaining it is expensive. Setting this attribute on the
    /// *application* element is the request. Until it is set, the whole subtree
    /// is invisible: there is no focused element, no selected text, and no
    /// range, so the capture chain cannot tell an Electron app apart from an app
    /// with nothing selected.
    ///
    /// Only `AXManualAccessibility` is set. The older `AXEnhancedUserInterface`
    /// flag has a similar effect on some apps but also changes window
    /// management behaviour in others, so it is left alone.
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        let application = applicationElement(pid: pid)
        let error = AXUIElementSetAttributeValue(
            application,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        if error != .success {
            log.debug("AXManualAccessibility refused, code \(error.rawValue, privacy: .public)")
        }
        return error == .success
    }

    // MARK: - Role checks

    /// True when the element is a password field.
    ///
    /// Checked on both the role and the subrole because AppKit's
    /// `NSSecureTextField` reports `AXTextField` with the secure *subrole* while
    /// some web and cross-platform toolkits put the same string in the *role*.
    /// Missing either spelling would mean reading a password.
    static func isSecureElement(_ element: AXUIElement) -> Bool {
        if let role = copyString(element, kAXRoleAttribute), secureRoleNames.contains(role) {
            return true
        }
        if let subrole = copyString(element, kAXSubroleAttribute), secureRoleNames.contains(subrole) {
            return true
        }
        return false
    }

    /// Whether writing into this element could plausibly work.
    ///
    /// Deliberately permissive. Settability of `AXSelectedText` or `AXValue` is
    /// the reliable signal, but several real editors (WebKit `contenteditable`
    /// among them) accept typing while reporting neither, so a known editable
    /// role also counts. Over-reporting costs an attempted paste that the target
    /// ignores, which `ReplacementService` detects and reports as
    /// `.copiedOnly`. Under-reporting would mean refusing to help in an app
    /// where help was possible.
    static func isEditable(_ element: AXUIElement, role: String?) -> Bool {
        if isSettable(element, kAXSelectedTextAttribute) { return true }
        if isSettable(element, kAXValueAttribute) { return true }
        if let role, editableRoleNames.contains(role) { return true }
        return false
    }
}
