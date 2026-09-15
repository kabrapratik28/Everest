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

    /// `autoReplace` is the user's setting, passed per call rather than held,
    /// for the reason `excludedBundleIDs` is: a value frozen at launch goes
    /// stale the moment they change it, and nothing tells them it has. No
    /// default — the product default lives in `AppSettings`, and a default
    /// here would be a second place for it to disagree from.
    public func apply(
        _ text: String, to snapshot: TargetSnapshot,
        autoReplace: Bool, keepOutOfHistory: Bool
    ) -> ReplaceOutcome {
        // Re-checked here, not only at capture: a password field can take
        // focus between capture and apply, and the user can revoke the
        // permission mid-rewrite. While secure input is on, synthetic
        // keystrokes are not delivered anyway, so route two would fail
        // silently rather than visibly.
        if system.isSecureEventInputEnabled() {
            return handOff(
                text, cause: .secureField, reason: "a password field has focus",
                keepOutOfHistory: keepOutOfHistory)
        }
        if !system.isAccessibilityTrusted() {
            return handOff(
                text, cause: .noAccessibility,
                reason: "Accessibility permission was revoked",
                keepOutOfHistory: keepOutOfHistory)
        }

        // Before the validator, on purpose, so nobody can later read a
        // passing validator as evidence that such a write would be safe.
        // `compare` mirrors the capture chain, so for a range-derived
        // snapshot it re-reads through the *same* shifted range, gets the
        // *same* shifted string, and confirms a match with itself.
        if snapshot.isRangeDerived {
            return handOff(
                text, cause: .rangeDerived,
                reason: "the selection was reconstructed from a range and cannot be verified",
                keepOutOfHistory: keepOutOfHistory)
        }

        let validator = TargetValidator(system: system, accessibility: accessibility)
        if let refusal = validator.validate(snapshot) {
            return handOff(
                text, cause: refusal.cause, reason: refusal.reason,
                keepOutOfHistory: keepOutOfHistory)
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

        // Route two. Editability is still re-derived live rather than read
        // from `snapshot.isEditable`, matching the live settability check
        // above: having one of the pair stale invites a future edit that
        // resolves the inconsistency the wrong way.
        //
        // With auto-replace on, `isEditable` stops being a veto and is not
        // consulted at all. It was always the weakest signal here: by this
        // line the validator has proved the
        // focused element reports our exact text at our exact range, which
        // says more about the target than any role or settability flag does.
        // Real editors — WebKit `contenteditable` among them — accept typing
        // while reporting neither attribute settable, and those were the
        // targets handing the user a clipboard and asking them to paste.
        //
        // Safe because of what cannot get here, not because of optimism. A
        // rung-9 snapshot carries a nil range, so `compare` answers `.unknown`
        // and the validator refuses it above — terminals, PDFs and Google Docs
        // are all rung 9 and none of them reaches this line. A rung-7 snapshot
        // is refused earlier still by `isRangeDerived`.
        //
        // And if the target really is read-only the paste is ignored,
        // consumption is not observed, and the outcome is the same copy-only
        // as before — one budget later.
        if !autoReplace, !accessibility.isEditable(snapshot.element) {
            return handOff(
                text, cause: .notEditable, reason: writeRefused,
                keepOutOfHistory: keepOutOfHistory)
        }
        return pasteReplace(text, to: snapshot, keepOutOfHistory: keepOutOfHistory)
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
    private func pasteReplace(
        _ text: String, to snapshot: TargetSnapshot, keepOutOfHistory: Bool
    ) -> ReplaceOutcome {
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

        // One deadline, shared by the observation and the hold below.
        let deadline = ContinuousClock.now + consumptionBudget
        let consumed = observeConsumption(of: snapshot, until: deadline)

        // The rewrite stays on the pasteboard for the whole budget, however
        // early consumption was read. `observeConsumption` accepts *any*
        // selection change as proof, so it can confirm a paste that has not
        // happened — and restoring on that reading put the user's clipboard
        // back while our ⌘V was still in flight, so the target then pasted
        // *their old clipboard* into their document and we reported
        // `.replaced`. A silent wrong write they may never notice.
        //
        // A budget bounds how long we wait, never how long we stay
        // responsible. The posted event is ours until the budget we chose for
        // it runs out.
        //
        // The cost is the other side of the same window: the pasteboard holds
        // our rewrite for up to the budget, so a user pressing ⌘V themselves
        // inside it gets the rewrite instead of what they copied. That is
        // visible the instant it happens and fixed by copying again, which is
        // not true of the write it replaces.
        hold(until: deadline)
        transaction.restoreIfUnchanged()

        guard consumed else {
            return handOff(
                text, cause: .pasteNotConsumed,
                reason: "the target did not accept the paste",
                keepOutOfHistory: keepOutOfHistory)
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
    private func observeConsumption(
        of snapshot: TargetSnapshot, until deadline: ContinuousClock.Instant
    ) -> Bool {
        let validator = TargetValidator(system: system, accessibility: accessibility)

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

    /// Spends whatever is left of the budget with the rewrite still on the
    /// pasteboard. Blocking, and it has to be.
    ///
    /// Handing the tail to a task would keep the borrow held past the return,
    /// so a second hotkey press inside the window would be refused with
    /// "another rewrite is using the clipboard" — false, where blocking makes
    /// it simply wait. It would also leave the restore owed by a task nobody
    /// awaits, so quitting inside the window strands the user's clipboard
    /// holding our rewrite. Doing it properly means giving the transaction a
    /// process-wide owner, which is the same design change `pasteReplace`
    /// already says is needed before this method may suspend.
    private func hold(until deadline: ContinuousClock.Instant) {
        while ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: consumptionPollInterval.timeInterval)
        }
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
    private func handOff(
        _ text: String, cause: CopyOnlyCause, reason: String, keepOutOfHistory: Bool
    ) -> ReplaceOutcome {
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

        transaction.writeDurable(text, keepOutOfHistory: keepOutOfHistory)
        return .copiedOnly(cause: cause, reason: reason)
    }
}
