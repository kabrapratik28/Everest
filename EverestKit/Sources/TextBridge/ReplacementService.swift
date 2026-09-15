import AppKit
import ApplicationServices

/// Writes the rewrite back, or reports honestly that it did not.
public final class ReplacementService {
    private let system: SystemProbing
    private let accessibility: AccessibilityReading & AccessibilityWriting
    private let keystroke: KeystrokePosting
    private let pasteboard: NSPasteboard
    private let borrow: PasteboardBorrow

    /// Apps differ by more than an order of magnitude in how long they take
    /// to handle a synthetic paste. Any single sleep is either a visible
    /// stutter for fast apps or a false failure for slow ones, and it tells
    /// you nothing about whether the paste landed. So this is a *ceiling on
    /// observation*, not a delay: a fast app is confirmed in one poll.
    private let consumptionBudget: Duration
    private let consumptionPollInterval: Duration

    public init(
        system: SystemProbing,
        accessibility: AccessibilityReading & AccessibilityWriting,
        keystroke: KeystrokePosting,
        pasteboard: NSPasteboard,
        borrow: PasteboardBorrow = .shared,
        consumptionBudget: Duration = .milliseconds(450),
        consumptionPollInterval: Duration = .milliseconds(8)
    ) {
        self.system = system
        self.accessibility = accessibility
        self.keystroke = keystroke
        self.pasteboard = pasteboard
        self.borrow = borrow
        self.consumptionBudget = consumptionBudget
        self.consumptionPollInterval = consumptionPollInterval
    }

    public func apply(_ text: String, to snapshot: TargetSnapshot) -> ReplaceOutcome {
        // Re-checked here, not only at capture: a password field can take
        // focus between capture and apply, and the user can revoke the
        // permission mid-rewrite. While secure input is on, synthetic
        // keystrokes are not delivered anyway, so route two would fail
        // silently rather than visibly.
        if system.isSecureEventInputEnabled() {
            return handOff(text, cause: .secureField, reason: "a password field has focus")
        }
        if !system.isAccessibilityTrusted() {
            return handOff(text, cause: .noAccessibility, reason: "Accessibility permission was revoked")
        }

        // Before the validator, on purpose, so nobody can later read a
        // passing validator as evidence that such a write would be safe.
        // `compare` mirrors the capture chain, so for a range-derived
        // snapshot it re-reads through the *same* shifted range, gets the
        // *same* shifted string, and confirms a match with itself.
        if snapshot.isRangeDerived {
            return handOff(
                text,
                cause: .rangeDerived,
                reason: "the selection was reconstructed from a range and cannot be verified"
            )
        }

        let validator = TargetValidator(system: system, accessibility: accessibility)
        if let refusal = validator.validate(snapshot) {
            return handOff(text, cause: refusal.cause, reason: refusal.reason)
        }

        // Route one. Settability is re-checked live rather than trusted from
        // the snapshot, because a field can go read-only while a rewrite runs.
        //
        // When the write reports success we stop. No confirming read: a false
        // negative there would fall through and paste as well, inserting the
        // rewrite twice, and a duplicated paragraph is unrecoverable where a
        // rewrite that quietly did not land is visible and repeatable.
        if accessibility.isSelectedTextSettable(snapshot.element),
            accessibility.setSelectedText(text, on: snapshot.element)
        {
            return .replaced
        }

        // Route two. Editability is re-derived live here rather than read
        // from `snapshot.isEditable`, matching the live settability check
        // above: having one of the pair stale invites a future edit that
        // resolves the inconsistency the wrong way.
        guard accessibility.isEditable(snapshot.element) else {
            return handOff(text, cause: .notEditable, reason: writeRefused)
        }
        return pasteReplace(text, to: snapshot)
    }

    private let writeRefused = "the target would not accept the write"

    /// Route two: pasteboard plus synthetic ⌘V, reached when an app answers
    /// accessibility reads but will not accept the write. Real web-based
    /// editors do this.
    ///
    /// **The blocking is the re-entrancy guard. Do not make this `async`.**
    /// `apply` contains no suspension point, so the main run loop is blocked
    /// and a second hotkey press cannot be delivered until this finishes. Add
    /// a suspension point and a second ⌘I can arrive while this transaction
    /// is between `writeTransient` and `restoreIfUnchanged`; the inner
    /// transaction then snapshots *our own scratch text* as if it were the
    /// user's clipboard and later restores that. The `changeCount` guard
    /// cannot help, because it protects against *other* writers and under
    /// re-entrancy the other writer is us. If the hitch genuinely has to go,
    /// the transaction has to become a process-wide resource with an owner,
    /// so a second rewrite is refused or queued rather than nested. That is a
    /// design change, not a keyword change.
    private func pasteReplace(_ text: String, to snapshot: TargetSnapshot) -> ReplaceOutcome {
        let transaction = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)

        // The front check. By the time you are in `restoreIfUnchanged` the
        // user's bytes are already gone from your copy and off the
        // pasteboard, and there is nothing left to be careful with.
        guard transaction.snapshot() else {
            return .heldForManualCopy(
                cause: Self.heldCause(transaction.fidelity),
                reason: Self.heldReason(writeRefused, transaction.fidelity))
        }

        transaction.writeTransient(text)
        keystroke.postPaste(pid: snapshot.pid)

        let consumed = observeConsumption(of: snapshot)
        transaction.restoreIfUnchanged()

        guard consumed else {
            return handOff(text, cause: .pasteNotConsumed, reason: "the target did not accept the paste")
        }
        return .replaced
    }

    /// Polls for the selection to stop matching, returning the moment it
    /// does. **Any change counts as proof.** A paste collapses the selection
    /// to a caret and moves the insertion point, so both the range and the
    /// text change. Checking for a *specific* new range would mean predicting
    /// the caret offset from the length of the inserted text, and the
    /// accessibility API is inconsistent about whether those offsets count
    /// UTF-16 units or composed characters, so any text containing an emoji
    /// would fail the prediction while having pasted perfectly.
    private func observeConsumption(of snapshot: TargetSnapshot) -> Bool {
        let validator = TargetValidator(system: system, accessibility: accessibility)
        let deadline = ContinuousClock.now + consumptionBudget

        while ContinuousClock.now < deadline {
            // A user who switches away clears the selection by losing focus,
            // and that would otherwise read as a successful paste.
            guard system.frontmostApp()?.pid == snapshot.pid else { return false }
            guard let live = accessibility.focusedElement(pid: snapshot.pid) else { return false }

            switch validator.compare(snapshot, live: live) {
            case .differs:
                return true
            case .matches, .unknown:
                // `unknown` means keep waiting: the element answered during
                // validation a moment earlier.
                break
            }
            Thread.sleep(forTimeInterval: consumptionPollInterval.timeInterval)
        }

        // Budget exhausted with the selection still intact means not
        // consumed, and we fall back rather than claim an edit the user
        // cannot see.
        return false
    }

    /// Two ways a borrow can be refused, and the user deserves to be told
    /// which: their clipboard is irreplaceable, or another rewrite has it.
    private static func heldCause(_ fidelity: Fidelity) -> HoldCause {
        fidelity == .lossy ? .clipboardTooLarge : .clipboardBusy
    }

    private static func heldReason(_ reason: String, _ fidelity: Fidelity) -> String {
        switch heldCause(fidelity) {
        case .clipboardTooLarge: "\(reason), and your clipboard is too large to put back"
        case .clipboardBusy: "\(reason), and another rewrite is using the clipboard"
        }
    }

    /// Every refusal path goes through here, so the promise carried by
    /// `copiedOnly` — "we did not place it for you, so it is on your
    /// clipboard" — cannot be forgotten in a new branch.
    private func handOff(_ text: String, cause: CopyOnlyCause, reason: String) -> ReplaceOutcome {
        let transaction = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)

        // A durable write destroys whatever is on the clipboard. That is the
        // accepted cost of `copiedOnly` when the content is something a
        // clipboard manager recorded and the user can get back. When we could
        // not even capture it, the overwrite is unrecoverable, so we touch
        // nothing and let the user decide.
        guard transaction.snapshot() else {
            return .heldForManualCopy(
                cause: Self.heldCause(transaction.fidelity),
                reason: Self.heldReason(reason, transaction.fidelity))
        }

        transaction.writeDurable(text)
        return .copiedOnly(cause: cause, reason: reason)
    }
}
