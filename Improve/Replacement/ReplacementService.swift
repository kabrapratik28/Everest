import AppKit
import ApplicationServices
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "replacement.service"
)

/// Puts a rewrite back where it came from, or refuses and says why.
///
/// The type this returns, `ReplaceOutcome`, is declared in
/// `Improve/Selection/TargetSnapshot.swift` because the MVP plan groups the
/// three shared types there.
///
/// Every refusal path leaves the rewritten text on the clipboard before
/// returning `.copiedOnly`, so the user always ends up with their work in hand
/// even when Everest declines to place it for them.
@MainActor
enum ReplacementService {

    /// How long to watch for evidence that the target consumed a paste.
    ///
    /// A fixed sleep is not used. Apps differ by more than an order of
    /// magnitude in how fast they handle a synthetic paste, so any single
    /// number is either a stutter for fast apps or a false failure for slow
    /// ones. This is a ceiling on observation, not a delay: a fast app is
    /// confirmed in roughly one poll.
    static let pasteObservationBudget: TimeInterval = 0.45

    static let pollInterval: TimeInterval = 0.008

    /// Writes `text` over the selection described by `snapshot`.
    ///
    /// Static because there is nothing to configure. `SelectionCoordinator` is
    /// an instance since it carries the exclusion list and the strategy cache;
    /// this side is a pure function of its arguments and the live system state.
    ///
    /// `pasteboard` defaults to the general one and exists so the guard tests
    /// can exercise every refusal path against a private pasteboard. Without
    /// it the tests would have to clobber the clipboard of whoever is using
    /// the machine, since `.copiedOnly` writes by definition. Production call
    /// sites pass nothing.
    static func apply(
        _ text: String,
        to snapshot: TargetSnapshot,
        pasteboard: NSPasteboard = .general
    ) -> ReplaceOutcome {
        if AXSelectionAdapter.isSecureInputActive() {
            return copiedOnly("A password field is active", text: text, pasteboard: pasteboard)
        }
        guard AXSelectionAdapter.isTrusted() else {
            return copiedOnly("Everest no longer has Accessibility permission", text: text, pasteboard: pasteboard)
        }

        // Fail closed on a capture we cannot trust the boundaries of.
        //
        // A range-derived snapshot came from `AXStringForRange`, which is
        // reached only when the app returned an empty `AXSelectedText`, which
        // is exactly the population exposed to the Chromium off-by-one. The
        // text may be shifted by one character at either end, and it is well
        // formed either way, so nothing can detect it. Writing it back would
        // replace the user's *actual* selection with a rewrite of slightly
        // different text.
        //
        // Revalidation cannot save us here and must not be relied on: it would
        // re-read through the same shifted range, get the same shifted string,
        // and confirm a match with itself. Checked before validation for that
        // reason, so nobody later mistakes a passing validator for safety.
        if snapshot.isRangeDerived {
            return copiedOnly(
                "This app does not report its selection precisely enough to replace safely",
                text: text, pasteboard: pasteboard)
        }

        switch TargetValidator.validate(snapshot) {
        case .mismatch(let reason):
            log.info("declined to write: \(reason, privacy: .public)")
            return copiedOnly(reason, text: text, pasteboard: pasteboard)
        case .ok:
            break
        }

        // Preferred route. The app performs the replacement itself, which means
        // it lands in one undo step, keeps the field's own formatting rules,
        // and never touches the clipboard.
        //
        // Settability is re-checked here rather than trusted from the snapshot
        // because a field can become read-only while a rewrite is generating,
        // and because the snapshot's `isEditable` is a permissive hint that
        // includes elements which report nothing.
        if AXSelectionAdapter.isSettable(snapshot.element, kAXSelectedTextAttribute) {
            let error = AXSelectionAdapter.setString(
                snapshot.element, kAXSelectedTextAttribute, text)
            if error == .success {
                // Trusted without a second confirming read, and on purpose. If
                // a confirmation came back inconclusive the only thing to do
                // with it would be to fall through and paste as well, and a
                // false negative there would insert the rewrite twice. A
                // duplicated paragraph is unrecoverable damage to the user's
                // document; a rewrite that quietly did not land is visible and
                // repeatable. The asymmetry decides it.
                return .replaced
            }
            log.debug("AXSelectedText write refused, code \(error.rawValue, privacy: .public)")
        }

        // Re-derived live, not read from the snapshot. Settability is
        // re-checked two lines above for the same reason, and having one of
        // the pair stale invites a future "why is only one of these fresh?"
        // edit that resolves it the wrong way.
        let role = AXSelectionAdapter.copyString(snapshot.element, kAXRoleAttribute) ?? snapshot.role
        guard AXSelectionAdapter.isEditable(snapshot.element, role: role) else {
            return copiedOnly("That text is not editable", text: text, pasteboard: pasteboard)
        }

        return pasteReplace(text, snapshot, pasteboard: pasteboard)
    }

    // MARK: - Paste route

    /// Borrows the clipboard, sends Command V, and watches the target's
    /// selection for proof that it landed.
    ///
    /// Reached when an app answers accessibility reads but will not accept an
    /// `AXSelectedText` write, which covers a good share of web based editors.
    /// It is never reached for an app we could not read, because
    /// `TargetValidator` refuses those before we get here. That is what makes
    /// a synthetic paste defensible at all: we have just proved, milliseconds
    /// ago, that the exact text we captured is still selected in the exact
    /// element we captured it from. The paste replaces that selection. It is
    /// never a paste "at the cursor".
    private static func pasteReplace(
        _ text: String,
        _ snapshot: TargetSnapshot,
        pasteboard: NSPasteboard
    ) -> ReplaceOutcome {
        let transaction = PasteboardTransaction(pasteboard: pasteboard)

        // Checked before the write, not after. If the user's clipboard is too
        // large to hold, overwriting it is unrecoverable, so route two is
        // abandoned rather than attempted. The outcome below still places the
        // rewrite on the clipboard, because that is what `.copiedOnly`
        // promises, but that is one deliberate overwrite the user is told
        // about rather than a silent loss inside a restore that claimed to
        // have worked.
        guard transaction.snapshot() else {
            return copiedOnly(
                "Your clipboard is too large for Everest to put back, so it was left alone",
                text: text, pasteboard: pasteboard)
        }

        transaction.writeTransient(text)

        SyntheticKeystroke.postCommand(.v)

        guard observeConsumption(snapshot) else {
            // The paste did not visibly land. Keep our text on the clipboard
            // rather than restoring, so the user can place it themselves.
            transaction.abandon()
            return copiedOnly("The app did not accept the paste", text: text, pasteboard: pasteboard)
        }

        transaction.restoreIfUnchanged()
        return .replaced
    }

    /// Waits for the target's selection to stop matching the snapshot.
    ///
    /// Any change is proof enough. A paste collapses the selection to a caret
    /// and shifts the insertion point, so both the range and the selected text
    /// move. Checking for a *specific* new range would mean predicting the
    /// caret offset from the length of the inserted text, and the accessibility
    /// API is inconsistent about whether those offsets count UTF-16 units or
    /// composed characters, so any text containing an emoji would fail the
    /// prediction while having pasted perfectly.
    ///
    /// The false positive is the user moving the caret themselves inside the
    /// observation window. It costs an incorrect `.replaced` label on an
    /// outcome the user can see for themselves.
    ///
    /// The frontmost app is re-checked on each poll. Without it, a user who
    /// switches away mid-observation clears the selection by losing focus,
    /// which reads as `.differs` and would be reported as a successful paste
    /// that may never have landed.
    private static func observeConsumption(_ snapshot: TargetSnapshot) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(pasteObservationBudget))
        while ContinuousClock.now < deadline {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
                log.debug("paste observation abandoned: the target app is no longer in front")
                return false
            }
            switch TargetValidator.compare(snapshot, against: snapshot.element) {
            case .differs:
                return true
            case .matches, .unknown:
                // `unknown` keeps waiting rather than concluding. The element
                // answered a moment ago during validation, so a blank answer
                // here is most likely the app being busy applying the paste.
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        // Budget spent with the selection still intact, or still unreadable.
        // Treated as "did not land": reporting a paste we cannot see would
        // leave the user believing their document was edited when it was not.
        return TargetValidator.compare(snapshot, against: snapshot.element) == .differs
    }

    // MARK: - Fallback

    /// Keeps the promise the outcome name makes.
    private static func copiedOnly(
        _ reason: String,
        text: String,
        pasteboard: NSPasteboard
    ) -> ReplaceOutcome {
        PasteboardTransaction.writeDurable(text, to: pasteboard)
        return .copiedOnly(reason: reason)
    }
}
