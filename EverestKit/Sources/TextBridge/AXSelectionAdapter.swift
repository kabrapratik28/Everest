import ApplicationServices
import Foundation

/// Stateless wrappers over the C accessibility API. **No policy lives here**
/// — the refusal order, the chain and the cache are `SelectionCoordinator`'s
/// job, and the safety gate is `TargetValidator`'s.
public final class AXSelectionAdapter: AccessibilityReading, AccessibilityWriting {
    private let systemWide = AXUIElementCreateSystemWide()

    public init() {}

    // MARK: - Focus

    func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// A security check, not tidiness. The exclusion list and the bundle
    /// identifier were evaluated against the *frontmost* process, so an
    /// element owned by a different process would be text that was never
    /// checked against the user's list of apps Everest must stay out of.
    func element(_ candidate: AXUIElement?, ownedBy pid: pid_t) -> AXUIElement? {
        guard let candidate, owner(of: candidate) == pid else { return nil }
        return candidate
    }

    /// Asks the system-wide element first, then the application element, and
    /// requires the answer to belong to `pid`.
    ///
    /// Measured, not theoretical: on macOS 26 `AXFocusedUIElement` on the
    /// system-wide element returns `kAXErrorCannotComplete` (-25204) against
    /// TextEdit while the identical query against TextEdit's own application
    /// element succeeds immediately. Treating that error as "nothing is
    /// selected" made Everest look broken in an ordinary Apple app. The
    /// system-wide element is still asked first because it reflects real
    /// keyboard focus including panels and helper processes; it is just not
    /// trustworthy alone.
    /// The decision, lifted away from the two C calls that feed it so it can
    /// be driven in a test. `perApp` is an autoclosure to keep the
    /// short-circuit: it is a synchronous cross-process call, and the common
    /// case answers from the system-wide element without paying for it.
    func focused(
        systemWide: AXUIElement?,
        perApp: @autoclosure () -> AXUIElement?,
        ownedBy pid: pid_t
    ) -> AXUIElement? {
        if let owned = element(systemWide, ownedBy: pid) { return owned }
        // Checked on this branch too. It used to be returned as-is, which put
        // the hole in exactly the branch that exists *because* the
        // system-wide query is unreliable — so the unchecked path was the one
        // ordinary apps take on macOS 26.
        return element(perApp(), ownedBy: pid)
    }

    public func focusedElement(pid: pid_t) -> AXUIElement? {
        focused(
            systemWide: copyElement(systemWide, kAXFocusedUIElementAttribute as String),
            perApp: copyElement(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as String),
            ownedBy: pid
        )
    }

    // MARK: - Reads

    public func role(of element: AXUIElement) -> String? {
        copyValue(element, kAXRoleAttribute as String) as? String
    }

    public func subrole(of element: AXUIElement) -> String? {
        copyValue(element, kAXSubroleAttribute as String) as? String
    }

    public func selectedText(of element: AXUIElement) -> String? {
        copyValue(element, kAXSelectedTextAttribute as String) as? String
    }

    public func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copyValue(element, kAXSelectedTextRangeAttribute as String),
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// `AXNumberOfCharacters`, asked rather than measuring `AXValue`. The only
    /// question is whether this element holds any text at all, and `AXValue`
    /// would drag an entire document across the process boundary to answer it.
    public func characterCount(of element: AXUIElement) -> Int? {
        copyValue(element, kAXNumberOfCharactersAttribute as String) as? Int
    }

    public func string(of element: AXUIElement, in range: CFRange) -> String? {
        var mutable = range
        guard let parameter = AXValueCreate(.cfRange, &mutable) else { return nil }

        var result: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                parameter,
                &result
            ) == .success
        else { return nil }
        return result as? String
    }

    /// Undocumented, and not in the SDK, so the string is spelled out.
    ///
    /// We deliberately do **not** set `AXEnhancedUserInterface`. It is the
    /// older flag with a similar effect on some apps, but it also changes
    /// window management behaviour in others, and toggling it on somebody's
    /// running app to read one sentence is not a trade worth making.
    public func enableManualAccessibility(pid: pid_t) {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    // MARK: - Editability

    static let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
    ]

    /// Over-reports on purpose, because the failure modes are not symmetric.
    /// Over-reporting costs an attempted paste the target ignores, which
    /// consumption observation detects and reports as copy-only.
    /// Under-reporting means refusing to help where help was possible, with
    /// no way for the user to override it. Real editors, WebKit
    /// `contenteditable` among them, accept typing while reporting neither
    /// attribute settable.
    ///
    /// Pasting into something genuinely non-editable is not a hazard here,
    /// because `TargetValidator` has already proved the focused element
    /// reports our exact selected text. An element that does that is a text
    /// element. The validator is what makes the paste safe, not this.
    static func isEditable(role: String?, selectedTextSettable: Bool, valueSettable: Bool) -> Bool
    {
        if selectedTextSettable || valueSettable { return true }
        guard let role else { return false }
        return editableRoles.contains(role)
    }

    public func isEditable(_ element: AXUIElement) -> Bool {
        Self.isEditable(
            role: role(of: element),
            selectedTextSettable: isSettable(element, kAXSelectedTextAttribute as String),
            valueSettable: isSettable(element, kAXValueAttribute as String)
        )
    }

    // MARK: - Writes

    public func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        isSettable(element, kAXSelectedTextAttribute as String)
    }

    public func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
    }

    // MARK: - Plumbing

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
