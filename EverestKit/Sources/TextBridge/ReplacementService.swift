import AppKit
import ApplicationServices

/// Writes the rewrite back, or reports honestly that it did not.
public final class ReplacementService {
    private let system: SystemProbing
    private let accessibility: AccessibilityReading & AccessibilityWriting
    private let keystroke: KeystrokePosting
    private let clipboard: ClipboardCapturing
    private let pasteboard: NSPasteboard
    private let borrow: PasteboardBorrow

    /// See `SelectionCoordinator.trace` for why this is a property rather
    /// than an init parameter.
    var trace: Tracing = OSLogTrace()

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
        clipboard: ClipboardCapturing,
        pasteboard: NSPasteboard,
        borrow: PasteboardBorrow = .shared,
        consumptionBudget: Duration = .milliseconds(450),
        consumptionPollInterval: Duration = .milliseconds(8)
    ) {
        self.system = system
        self.accessibility = accessibility
        self.keystroke = keystroke
        self.clipboard = clipboard
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
    /// One choke point for the outcome, so a new exit cannot forget to
    /// record itself — the same reason the length check sits at the end of
    /// the capture chain rather than in each rung. A trail with a hole in it
    /// is worth nothing on the day it is read, and the hole is invisible
    /// until then.
    public func apply(
        _ text: String, to snapshot: TargetSnapshot,
        autoReplace: Bool, keepOutOfHistory: Bool
    ) -> ReplaceOutcome {
        let outcome = decide(
            text, to: snapshot, autoReplace: autoReplace, keepOutOfHistory: keepOutOfHistory)
        trace.record(.outcome(outcome))
        return outcome
    }

    private func decide(
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

        // Ahead of *every* write attempt, because both paste routes are
        // downstream of here and they are reached by different doors: route
        // two from the tail of this function, `pasteUnverifiable` from the
        // validator refusal below. It used to sit inside the second one,
        // which is why Terminal.app was never covered — measured, it
        // supports `AXSelectedText`, so it is captured at rung 5 and its
        // snapshot is not `viaClipboard`.
        //
        // Route one is collateral and costs nothing: `AXValue` is not
        // settable in Terminal.app, so the accessibility write declines
        // there anyway.
        if let bundleID = snapshot.bundleID,
            Self.insertsRatherThanReplaces.contains(bundleID.lowercased())
        {
            return held("this app inserts a paste rather than replacing the selection")
        }

        let validator = TargetValidator(system: system, accessibility: accessibility)
        if let refusal = validator.validate(snapshot) {
            // Only "could not verify" is overridable, and only for a rung-9
            // snapshot, and only with auto-replace on. `.notFrontmost` and
            // `.secure` are checked *by the same call* and are never
            // overridden — which is the whole reason this branches on the
            // refusal rather than skipping the validator: the paste path
            // would otherwise post ⌘V at an app the user has left, and
            // `postToPid` delivers it there whether or not they are looking.
            trace.record(.writeRefused(refusal))
            if autoReplace, snapshot.viaClipboard, refusal == .unverifiable {
                trace.record(.pasteOverrideEntered)
                return pasteUnverifiable(
                    text, to: snapshot, keepOutOfHistory: keepOutOfHistory)
            }
            trace.record(
                .pasteOverrideSkipped(
                    !autoReplace
                        ? .autoReplaceOff
                        : (snapshot.viaClipboard ? .refusalIsReal : .notClipboardCapture)))
            return handOff(
                text, cause: refusal.cause, reason: refusal.reason,
                keepOutOfHistory: keepOutOfHistory)
        }

        // Route one. Settability is re-checked live rather than trusted from
        // the snapshot, because a field can go read-only while a rewrite runs.
        //
        // **A reported success is not a write.** Measured in Chrome 153
        // against Linear, 2026-09-15: the field reports `settable`,
        // `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` returns
        // `.success`, and the value is unchanged at +120 ms and at +1 s.
        // React owns the input and never sees the AX write. Reported the same
        // way on chatgpt.com and chat.google.com, while a plain
        // `contenteditable` in the same browser replaces correctly — which is
        // what made it look browser-shaped when it is framework-shaped.
        //
        // This used to stop here on `true`, on the grounds that a false
        // negative would paste as well and duplicate a paragraph. That
        // reasoning still holds and is why the confirm below is **positive
        // proof of failure, never absence of proof of success** — the same
        // shape as the rung-9 confirm and for the same inverted-cost reason.
        // Both signals must say nothing moved: the selection still reports
        // our exact captured text *and* the element holds the same number of
        // characters. A landed write moves at least one, unless the rewrite
        // is byte-identical to the original, in which case the paste that
        // follows produces the identical result anyway.
        if accessibility.isSelectedTextSettable(snapshot.element) {
            let countBefore = accessibility.characterCount(of: snapshot.element)
            if accessibility.setSelectedText(text, on: snapshot.element) {
                let stillSelected = accessibility.selectedText(of: snapshot.element)
                let countAfter = accessibility.characterCount(of: snapshot.element)
                let nothingMoved = stillSelected == snapshot.text && countAfter == countBefore
                if !nothingMoved {
                    return .replaced
                }
                trace.record(.writeDropped)
            }
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

    /// Apps where ⌘V **succeeds and does not replace** — it inserts at the
    /// shell prompt, and a rewrite ending in a newline is a rewrite that ran.
    ///
    /// A bundle-id list is the last thing this module should want, and it is
    /// here because no observation can substitute for it: a terminal's paste
    /// *is* consumed, so every signal we have says it worked. Everything else
    /// self-corrects — a PDF simply does not take the paste, and the
    /// confirming re-read catches that. **This is not a denylist to grow.**
    /// The entry test is "paste succeeds but does not replace", and anything
    /// failing it belongs in the user's privacy exclusion list instead, which
    /// already stops Everest touching an app entirely.
    /// **Verified against a real `Info.plist`**, because the first version of
    /// this list was written from memory and `io.alacritty` was wrong — the
    /// app declares `org.alacritty`, so an Alacritty user got a rewrite at
    /// their shell prompt, which is the exact hazard the list exists for.
    static let insertsRatherThanReplaces: Set<String> = [
        // Read locally with `defaults read <app>/Contents/Info`.
        "com.apple.terminal",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        // Read from the project's own `Info.plist`.
        "org.alacritty",
        // **Unverified — recalled, not checked.** Not installed here and no
        // authoritative plist to hand. Kept because a wrong entry is no worse
        // than a missing one and a right one protects; do not promote any of
        // these to "verified" without reading the plist.
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    /// Rung 9 left no element and no range, so the validator can never
    /// confirm this target — but the mechanism that captured the text still
    /// works, and asking it again is evidence the validator does not have.
    ///
    /// Three synthetic copies across a rewrite is the cost, and it is paid
    /// because the alternative was `.copiedOnly`, whose durable write
    /// destroyed the user's clipboard on every single rewrite in these apps.
    /// Each is bounded by the copy budget and returns as soon as the change
    /// count moves — measured warm, tens of milliseconds.
    ///
    /// Nothing here runs inside a transaction that is already open: the
    /// borrow is exclusive, so a nested `copySelection` would be refused
    /// outright. The re-read happens before the transaction and the
    /// confirmation after it, and both block rather than suspend, so
    /// `pasteReplace`'s no-suspension-point invariant still holds.
    /// Re-asked immediately before every synthetic keystroke, because
    /// "still frontmost, still not secure" is a *live* condition and this
    /// path spends over a second not asking. `observeConsumption` already
    /// polls frontmost every 8 ms on exactly that reasoning; the blocking
    /// copies here took the opposite view.
    ///
    /// The window that makes it a P0: the secure-input check at rung 9
    /// closes the password gap at capture, and the re-read reopens it for up
    /// to 520 ms downstream — a field taking focus in that time would be
    /// pasted into, and a third ⌘C posted at it afterwards.
    private func targetStillSafe(_ snapshot: TargetSnapshot) -> Bool {
        guard !system.isSecureEventInputEnabled() else { return false }
        guard system.frontmostApp()?.pid == snapshot.pid else { return false }
        guard let live = accessibility.focusedElement(pid: snapshot.pid) else { return true }
        return !accessibility.isSecure(live)
    }

    private func pasteUnverifiable(
        _ text: String, to snapshot: TargetSnapshot, keepOutOfHistory: Bool
    ) -> ReplaceOutcome {
        let reRead = clipboard.copySelection(pid: snapshot.pid)
        guard case let .captured(live) = reRead, live == snapshot.text else {
            trace.record(.reRead(matched: false))
            return held("the selection changed while the rewrite was being written")
        }

        trace.record(.reRead(matched: true))

        // The re-read blocked. Nothing about the world is known to still
        // hold, and the next statement posts a keystroke.
        guard targetStillSafe(snapshot) else {
            return held("focus moved while the selection was being checked")
        }

        let transaction = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
        guard transaction.snapshot() else {
            return .heldForManualCopy(
                cause: Self.heldCause(transaction.refusal),
                reason: Self.heldReason(writeRefused, transaction.refusal))
        }

        transaction.writeTransient(text)
        keystroke.postPaste(pid: snapshot.pid)
        hold(until: ContinuousClock.now + consumptionBudget)
        guard transaction.restoreIfUnchanged() else {
            return .heldForManualCopy(
                cause: .clipboardChanged,
                reason:
                    "something else was copied while the rewrite ran, so the rewrite is only in this panel"
            )
        }

        // The hold blocked too, and the confirm is a third synthetic ⌘C. A
        // copy posted at an app they have left reads a background document
        // and disturbs the clipboard to do it.
        guard targetStillSafe(snapshot) else {
            return held("focus moved before the paste could be confirmed")
        }

        // **The failure signal is the reliable one.** This used to accept only
        // "nothing came back" as proof of a landed paste, and an absence has
        // more than one cause: Sublime's `copy_with_empty_selection` defaults
        // on, so ⌘C at a collapsed caret hands back the whole current line
        // and a successful paste read as a failed one.
        //
        // Comparing against the *rewrite* cannot work in either direction —
        // a single-line paste makes the copied line wider than the rewrite,
        // a multi-line paste makes it narrower. Comparing against what was
        // captured can: a paste that was ignored leaves the selection exactly
        // as it was, so ⌘C returns exactly that.
        //
        // **Do not carry `observeConsumption`'s trade over here.** That one
        // takes any change as proof because its false negative copies a
        // rewrite it already pasted and the user duplicates a paragraph. Here
        // the costs invert: a false negative shows a panel and keeps the
        // rewrite, a false positive dismisses with a tick and the rewrite is
        // gone from the panel *and* the clipboard. Same question, opposite
        // answer, which is why unknown holds rather than passing.
        switch clipboard.copySelection(pid: snapshot.pid) {
        case let .captured(after) where after == snapshot.text:
            trace.record(.pasteConfirmed(false))
            return held("the target did not accept the paste")
        case .unavailable:
            trace.record(.pasteConfirmed(false))
            return held("the paste could not be confirmed")
        case .captured, .nothingCopied:
            trace.record(.pasteConfirmed(true))
            return .replaced
        }
    }

    /// The rewrite stays in the panel and the clipboard is not touched. This
    /// is `copiedOnly`'s opposite on purpose: that case promises a durable
    /// write, and the durable write is what was destroying the clipboard.
    private func held(_ reason: String) -> ReplaceOutcome {
        .heldForManualCopy(cause: .notPasted, reason: reason)
    }

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
                cause: Self.heldCause(transaction.refusal),
                reason: Self.heldReason(writeRefused, transaction.refusal))
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
        let restored = transaction.restoreIfUnchanged()

        guard consumed else {
            // A declined restore means one thing here — the snapshot was
            // faithful, so the only way back is a change count that moved:
            // the user copied something while the rewrite ran. Handing off
            // would write the rewrite straight over it, destroying a fresh
            // copy with the mechanism that exists to protect it.
            //
            // This path was opened by giving the borrow back on a declined
            // restore. Before that the leak blocked `handOff` and the user's
            // copy survived behind a false "another rewrite is using the
            // clipboard" — a wrong message is not worth a leak, but fixing
            // the leak turned the wrong message into data loss, and this is
            // the other half.
            guard restored else {
                return .heldForManualCopy(
                    cause: .clipboardChanged,
                    reason:
                        "the target did not accept the paste, and something else was copied while it ran, so the rewrite is only in this panel"
                )
            }
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
    private static func heldCause(_ refusal: BorrowRefusal?) -> HoldCause {
        switch refusal {
        case .tooLargeToRestore: .clipboardTooLarge
        case .changedDuringRead: .clipboardChanged
        case .alreadyBorrowed, nil: .clipboardBusy
        }
    }

    /// Switched on `Fidelity` rather than on the cause, so the two stay a
    /// pair without `.clipboardChanged` having to appear as a case that
    /// `heldCause` cannot return. That one is not a borrow refusal: it is
    /// raised where the newer content is known, and carries its own sentence.
    private static func heldReason(_ reason: String, _ refusal: BorrowRefusal?) -> String {
        switch refusal {
        case .tooLargeToRestore: "\(reason), and your clipboard is too large to put back"
        case .changedDuringRead:
            "\(reason), and something else was copied while it ran"
        case .alreadyBorrowed, nil: "\(reason), and another rewrite is using the clipboard"
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
                cause: Self.heldCause(transaction.refusal),
                reason: Self.heldReason(reason, transaction.refusal))
        }

        transaction.writeDurable(text, keepOutOfHistory: keepOutOfHistory)
        return .copiedOnly(cause: cause, reason: reason)
    }
}
