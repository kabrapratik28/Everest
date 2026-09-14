import AppKit
import ApplicationServices
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "selection.coordinator"
)

/// Reads the user's current selection out of whatever app is in front.
///
/// This is the only entry point. `AXSelectionAdapter` and
/// `ClipboardSelectionAdapter` are mechanism; this type is policy: what is
/// refused, in what order things are tried, and what is remembered between
/// attempts.
///
/// The ordering of the refusals is not cosmetic. No text is read, by any path,
/// until both secure checks and the exclusion check have passed. Every branch
/// below preserves that.
@MainActor
final class SelectionCoordinator {

    /// Which route worked last time for a given app.
    ///
    /// Cached because a failed accessibility read is not free: it is
    /// cross-process IPC that costs up to the messaging timeout, and the chain
    /// makes several. An app that answers nothing would spend most of a second
    /// proving it again on every hotkey press.
    enum Strategy: String, Sendable {
        case axSelectedText
        case axStringForRange
        case manualAccessibility
        case clipboard
    }

    private struct CacheEntry {
        let appVersion: String?
        let strategy: Strategy
        let recordedAt: ContinuousClock.Instant
    }

    /// Bundle identifiers Everest refuses to read. Injected rather than read
    /// from `AppSettings` so this layer stays independent of RewriteCore.
    ///
    /// Mutable on purpose: the user can edit the list in Settings while the app
    /// runs, and a value frozen at construction would go stale in a way nobody
    /// would notice until Everest read from a password manager it was supposed
    /// to be excluded from.
    var excludedBundleIDs: [String]

    /// How long a cached strategy is trusted before the chain is probed again.
    ///
    /// Without this, one bad reading pins an app to the clipboard path forever.
    /// Electron apps in particular answer nothing until something enables their
    /// accessibility tree, and the app that did the enabling may have been a
    /// screen reader that has since quit, or the target may have relaunched.
    /// The cache is a hint, never a gate.
    static let strategyReprobeInterval: Duration = .seconds(600)

    /// How long to let a Chromium or Electron process build its accessibility
    /// tree after `AXManualAccessibility` is set. The tree is created in
    /// response to the attribute write and is not ready when the call returns.
    static let manualAccessibilitySettle: TimeInterval = 0.10

    private var cache: [String: CacheEntry] = [:]
    private let clipboard: ClipboardSelectionAdapter

    init(
        excludedBundleIDs: [String],
        clipboard: ClipboardSelectionAdapter = ClipboardSelectionAdapter()
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.clipboard = clipboard
    }

    // MARK: - Capture

    /// Reads the current selection, or throws explaining why it did not.
    ///
    /// Order, and why each step is where it is:
    ///
    /// 1. Secure input. A process-wide flag, needs no permission, costs
    ///    nothing, and is checked before we even find out which app is in
    ///    front.
    /// 2. The frontmost app's identity, from `NSWorkspace`, which needs no
    ///    accessibility permission.
    /// 3. The exclusion list, so an excluded app is refused before a single
    ///    accessibility call is made against it.
    /// 4. Accessibility permission, because everything after this point needs
    ///    it, including the synthetic keystroke.
    /// 5. Focus resolution, escalating to `AXManualAccessibility` if the app
    ///    answers nothing. This happens **before** any strategy is chosen,
    ///    including a cached one, because step 6 depends on it.
    /// 6. The secure *role* check, before any text leaves any element and
    ///    before any keystroke is posted. Step 1 catches a password manager
    ///    that has taken secure input; this catches a password field that has
    ///    not, which is the normal case for a web or Electron password input.
    /// 7. The read chain itself.
    ///
    /// Steps 5 and 6 sit above the strategy cache on purpose. An earlier
    /// version dispatched a remembered `.clipboard` app straight to the
    /// synthetic copy, which let the cache skip the secure-role rung entirely.
    /// The cache is allowed to skip work. It is never allowed to skip a
    /// refusal.
    func capture() throws -> TargetSnapshot {
        if AXSelectionAdapter.isSecureInputActive() {
            log.info("refused: secure input is active")
            throw CaptureError.secureField
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw CaptureError.noSelection
        }
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let appVersion = Self.versionString(for: application)

        if let bundleID, isExcluded(bundleID) {
            log.info("refused: \(bundleID, privacy: .public) is excluded")
            throw CaptureError.excludedApp(bundleID)
        }

        guard AXSelectionAdapter.isTrusted() else {
            throw CaptureError.accessibilityNotGranted
        }

        // Resolve focus once, for every strategy, escalating the accessibility
        // tree if the app answers nothing. This is what makes the secure-role
        // check below reachable for a Chromium or Electron password input,
        // whose tree would otherwise be invisible.
        let focus = resolveFocus(pid: pid)
        try refuseIfSecure(focus.element)

        let cached = cachedStrategy(bundleID: bundleID, appVersion: appVersion)

        // A remembered clipboard app skips the accessibility *reads*. It does
        // not skip anything above this line.
        if cached == .clipboard {
            if let snapshot = try captureViaClipboard(
                pid: pid, bundleID: bundleID, appVersion: appVersion, element: focus.element)
            {
                return snapshot
            }
            log.debug("cached clipboard strategy came up empty, re-probing")
        }

        if let snapshot = try captureViaAccessibility(
            pid: pid,
            bundleID: bundleID,
            appVersion: appVersion,
            element: focus.element,
            allowManualRetry: !focus.usedManualAccessibility)
        {
            return snapshot
        }

        if cached != .clipboard,
           let snapshot = try captureViaClipboard(
               pid: pid, bundleID: bundleID, appVersion: appVersion, element: focus.element)
        {
            return snapshot
        }

        throw CaptureError.noSelection
    }

    // MARK: - Focus and the secure refusal

    struct FocusResolution {
        let element: AXUIElement?
        /// True when the accessibility tree had to be switched on to get here,
        /// so the read chain must not pay the settle cost a second time.
        let usedManualAccessibility: Bool
    }

    /// Finds the focused element, switching on a Chromium or Electron tree if
    /// the app answers nothing at all.
    ///
    /// The escalation lives here rather than only inside the read chain
    /// because the secure-role refusal needs an element to inspect, and the
    /// apps most likely to host a password field we cannot otherwise see are
    /// exactly the ones whose tree is switched off.
    func resolveFocus(pid: pid_t) -> FocusResolution {
        if let element = AXSelectionAdapter.focusedElement(pid: pid) {
            return FocusResolution(element: element, usedManualAccessibility: false)
        }
        guard AXSelectionAdapter.enableManualAccessibility(pid: pid) else {
            return FocusResolution(element: nil, usedManualAccessibility: false)
        }
        Thread.sleep(forTimeInterval: Self.manualAccessibilitySettle)
        return FocusResolution(
            element: AXSelectionAdapter.focusedElement(pid: pid),
            usedManualAccessibility: true
        )
    }

    /// Throws `.secureField` if the element is a password field.
    ///
    /// A nil element means the app exposes no accessibility tree even after
    /// escalation, so there is nothing to inspect and only the process-wide
    /// flag stands. That residual gap is documented in `AGENTS.md`; the
    /// mitigation available to the user is the exclusion list.
    func refuseIfSecure(_ element: AXUIElement?) throws {
        guard let element else { return }
        if AXSelectionAdapter.isSecureElement(element) {
            log.info("refused: focused element is a secure field")
            throw CaptureError.secureField
        }
    }

    // MARK: - Accessibility path

    /// Returns `nil` when this app told us nothing, which means "try the next
    /// thing". Throws when it told us something that ends the attempt.
    func captureViaAccessibility(
        pid: pid_t,
        bundleID: String?,
        appVersion: String?,
        element: AXUIElement?,
        allowManualRetry: Bool
    ) throws -> TargetSnapshot? {
        guard let element else {
            // No focused element at all. Normal for a Chromium or Electron
            // process with its accessibility tree still switched off.
            return try retryWithManualAccessibility(
                pid: pid, bundleID: bundleID, appVersion: appVersion, allowed: allowManualRetry)
        }

        // Already checked by `capture()` on this same element. Repeated because
        // the manual-accessibility retry re-enters here with a *different*
        // element, one that did not exist when the first check ran.
        try refuseIfSecure(element)

        let role = AXSelectionAdapter.copyString(element, kAXRoleAttribute)
        let selectedText = AXSelectionAdapter.copyString(element, kAXSelectedTextAttribute)
        let range = AXSelectionAdapter.copyRange(element, kAXSelectedTextRangeAttribute)

        // An empty `AXSelectedText` is ambiguous: it means either "nothing is
        // selected" or "this app does not implement the attribute". The range
        // is what tells the two apart. A reported range of length zero is the
        // app saying, clearly, that the caret is sitting somewhere with nothing
        // selected. That is a full stop, not a reason to try the clipboard: a
        // synthetic copy with nothing selected copies nothing, and anything we
        // then read would be the user's pre-existing clipboard.
        //
        // A length zero range together with non-empty selected text is a
        // contradiction, and it is resolved the same conservative way. Acting
        // on the text and writing it back through a zero length range would
        // insert a second copy instead of replacing anything.
        if let range, range.length == 0 {
            throw CaptureError.noSelection
        }

        var text: String?
        var strategy: Strategy = .axSelectedText
        var isRangeDerived = false

        if let selectedText, !selectedText.isEmpty {
            // Preferred even when a range is also available. Chromium and
            // Electron have a long standing off-by-one in
            // `AXSelectedTextRange`, so `AXStringForRange` can come back
            // shifted by a character. `AXSelectedText` is the app's own answer
            // to "what is selected" and does not go through that arithmetic.
            // The shifted-by-one text is still perfectly well formed, so no
            // amount of inspection downstream would catch the mistake.
            text = selectedText
        } else if let range, range.length > 0 {
            // Reached only when `AXSelectedText` is empty, which is precisely
            // the population where the Chromium off-by-one has no mitigation:
            // a shifted range yields well formed but wrong text, and nothing
            // downstream can tell. The capture is still useful, so we take it,
            // but it is marked so that `ReplacementService` will never write
            // it back. See the fail-closed note in AGENTS.md.
            let fromRange = AXSelectionAdapter.stringForRange(element, range)
            if let fromRange, !fromRange.isEmpty {
                text = fromRange
                strategy = .axStringForRange
                isRangeDerived = true
            }
        }

        guard let text else {
            return try retryWithManualAccessibility(
                pid: pid, bundleID: bundleID, appVersion: appVersion, allowed: allowManualRetry)
        }

        // Counted, never altered. Trimming here would corrupt the replacement:
        // the text we hand back is also the text `TargetValidator` compares
        // against the live selection, and a trimmed copy would never match.
        if text.count > CaptureLimits.maxInputCharacters {
            throw CaptureError.tooLong(text.count)
        }

        record(strategy, bundleID: bundleID, appVersion: appVersion)
        log.debug("captured via \(strategy.rawValue, privacy: .public), \(text.count, privacy: .public) characters")

        return TargetSnapshot(
            pid: pid,
            bundleID: bundleID,
            appVersion: appVersion,
            element: element,
            text: text,
            range: range,
            role: role,
            isEditable: AXSelectionAdapter.isEditable(element, role: role),
            capturedAt: ContinuousClock.now,
            isRangeDerived: isRangeDerived
        )
    }

    /// Switches on a Chromium or Electron accessibility tree and runs the chain
    /// once more. Once, not in a loop: if the tree did not appear after the
    /// settle period, it is not going to, and a retry loop would turn a failed
    /// capture into a visible freeze.
    private func retryWithManualAccessibility(
        pid: pid_t,
        bundleID: String?,
        appVersion: String?,
        allowed: Bool
    ) throws -> TargetSnapshot? {
        guard allowed else { return nil }
        guard AXSelectionAdapter.enableManualAccessibility(pid: pid) else { return nil }
        Thread.sleep(forTimeInterval: Self.manualAccessibilitySettle)

        // Re-resolve: the whole point is that the element did not exist before
        // the tree was switched on. The inner call re-runs the secure refusal
        // on whatever it finds.
        let element = AXSelectionAdapter.focusedElement(pid: pid)
        guard let snapshot = try captureViaAccessibility(
            pid: pid, bundleID: bundleID, appVersion: appVersion,
            element: element, allowManualRetry: false)
        else { return nil }

        // Overwrite whatever the inner call recorded. What matters for next
        // time is that this app needs the attribute set first.
        record(.manualAccessibility, bundleID: bundleID, appVersion: appVersion)
        return snapshot
    }

    // MARK: - Clipboard path

    func captureViaClipboard(
        pid: pid_t,
        bundleID: String?,
        appVersion: String?,
        element focused: AXUIElement?
    ) throws -> TargetSnapshot? {
        // Before the keystroke. `capture()` has already refused a secure
        // element, and this repeats it at the point of no return, because this
        // is the one path that makes another process write the user's
        // clipboard and there is no undoing that once it has happened.
        try refuseIfSecure(focused)

        guard let text = clipboard.copySelection() else { return nil }

        if text.count > CaptureLimits.maxInputCharacters {
            throw CaptureError.tooLong(text.count)
        }

        // Best effort element, used only so the snapshot has something to hold.
        // For a genuinely opaque app this is the application element, which
        // reports no selection, so `TargetValidator` will refuse to write and
        // the rewrite comes back as `.copiedOnly`. That is the intended
        // outcome: an app we cannot read is an app we cannot safely write to.
        let element = focused ?? AXSelectionAdapter.applicationElement(pid: pid)
        let role = AXSelectionAdapter.copyString(element, kAXRoleAttribute)

        record(.clipboard, bundleID: bundleID, appVersion: appVersion)
        log.debug("captured via clipboard, \(text.count, privacy: .public) characters")

        return TargetSnapshot(
            pid: pid,
            bundleID: bundleID,
            appVersion: appVersion,
            element: element,
            text: text,
            range: nil,
            role: role,
            isEditable: AXSelectionAdapter.isEditable(element, role: role),
            capturedAt: ContinuousClock.now
        )
    }

    // MARK: - Exclusion

    private func isExcluded(_ bundleID: String) -> Bool {
        let candidate = bundleID.lowercased()
        return excludedBundleIDs.contains { $0.lowercased() == candidate }
    }

    // MARK: - Strategy cache

    /// Keyed by bundle identifier, with the version stored alongside rather
    /// than folded into the key. A version mismatch therefore *replaces* the
    /// entry instead of adding a second one, so an app that updates weekly
    /// cannot grow the cache without bound, and the old reading is gone rather
    /// than merely unreachable.
    private func cachedStrategy(bundleID: String?, appVersion: String?) -> Strategy? {
        guard let bundleID, let entry = cache[bundleID] else { return nil }

        guard entry.appVersion == appVersion else {
            // The app was updated. Everything we learned about its
            // accessibility support was learned about a different binary.
            cache[bundleID] = nil
            return nil
        }
        guard entry.recordedAt.duration(to: ContinuousClock.now) < Self.strategyReprobeInterval else {
            cache[bundleID] = nil
            return nil
        }
        return entry.strategy
    }

    private func record(_ strategy: Strategy, bundleID: String?, appVersion: String?) {
        guard let bundleID else { return }
        cache[bundleID] = CacheEntry(
            appVersion: appVersion,
            strategy: strategy,
            recordedAt: ContinuousClock.now
        )
    }

    /// Marketing version and build number together. The build number alone
    /// would miss a rebuilt release; the marketing version alone would miss
    /// every nightly and every Electron app that ships fixes without bumping
    /// it.
    private static func versionString(for application: NSRunningApplication) -> String? {
        guard let url = application.bundleURL, let bundle = Bundle(url: url) else { return nil }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return nil
        }
    }
}
