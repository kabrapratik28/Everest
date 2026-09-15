import ApplicationServices
import Testing

@testable import TextBridge

/// `AXSelectionAdapter` is mostly thin, policy-free wrappers over the C
/// accessibility API, and those cannot be driven without a live third-party
/// app and a granted permission. Two parts of it are real decisions rather
/// than wrappers, and those are driven here.
@Suite("Accessibility adapter")
struct AXSelectionAdapterTests {

    /// The pid check is a security check, not tidiness. The exclusion list
    /// and the bundle identifier were evaluated against the *frontmost*
    /// process. An element owned by a different process would be text that
    /// was never checked against the user's list of apps Everest must stay
    /// out of. System-wide focus is still asked first, because it reflects
    /// real keyboard focus including panels and helper processes; it is just
    /// not trustworthy alone.
    @Test("a focused element owned by another process is rejected")
    func focusBelongingToAnotherProcessIsRejected() {
        let adapter = AXSelectionAdapter()
        let stray = AXUIElementCreateApplication(4242)

        #expect(adapter.element(stray, ownedBy: 4242) != nil)
        #expect(adapter.element(stray, ownedBy: 501) == nil)
        #expect(adapter.element(nil, ownedBy: 4242) == nil)
    }

    /// And *both* candidates go through it. The fallback branch returned
    /// unchecked, so the security check had a hole in exactly the branch that
    /// exists because the system-wide query is unreliable: on macOS 26 that
    /// query returns `kAXErrorCannotComplete` against ordinary apps, and
    /// whatever the per-app query answered was then used without anyone
    /// asking who owned it.
    @Test("the per-app fallback is ownership-checked too, not just the system-wide answer")
    func theFallbackFocusIsAlsoOwnershipChecked() {
        let adapter = AXSelectionAdapter()
        let ours = AXUIElementCreateApplication(501)
        let stray = AXUIElementCreateApplication(4242)

        // System-wide answers for another process, so the fallback is used.
        #expect(adapter.focused(systemWide: stray, perApp: ours, ownedBy: 501) != nil)
        #expect(adapter.focused(systemWide: stray, perApp: stray, ownedBy: 501) == nil)
        // System-wide answers for ours, so the fallback is never consulted.
        #expect(adapter.focused(systemWide: ours, perApp: stray, ownedBy: 501) != nil)
    }

    /// Over-reporting is deliberate, because the failure modes are not
    /// symmetric. Over-reporting costs an attempted paste that the target
    /// ignores, which consumption observation detects and reports as
    /// copy-only. Under-reporting means refusing to help in an app where help
    /// was possible, and the user has no way to override it.
    ///
    /// Real editors, including WebKit `contenteditable`, accept typing while
    /// reporting neither `AXSelectedText` nor `AXValue` as settable.
    @Test("a known editable role counts as editable even when nothing reports settable")
    func editableRoleIsEnoughOnItsOwn() {
        #expect(
            AXSelectionAdapter.isEditable(
                role: kAXTextAreaRole as String,
                selectedTextSettable: false,
                valueSettable: false
            ))
        #expect(
            AXSelectionAdapter.isEditable(
                role: kAXTextFieldRole as String,
                selectedTextSettable: false,
                valueSettable: false
            ))
    }

    @Test("a settable attribute counts as editable whatever the role says")
    func settableAttributeIsEnoughOnItsOwn() {
        #expect(
            AXSelectionAdapter.isEditable(
                role: "AXUnknownCustomRole", selectedTextSettable: true, valueSettable: false))
        #expect(
            AXSelectionAdapter.isEditable(
                role: "AXUnknownCustomRole", selectedTextSettable: false, valueSettable: true))
    }

    @Test("a non-editable role with nothing settable is not editable")
    func staticTextWithNothingSettableIsNotEditable() {
        #expect(
            AXSelectionAdapter.isEditable(
                role: kAXStaticTextRole as String,
                selectedTextSettable: false,
                valueSettable: false
            ) == false)
        #expect(
            AXSelectionAdapter.isEditable(
                role: nil, selectedTextSettable: false, valueSettable: false) == false)
    }
}
