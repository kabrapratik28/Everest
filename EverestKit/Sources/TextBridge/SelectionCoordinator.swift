import ApplicationServices
import Foundation

/// All the capture policy. The only entry point for reading a selection.
public final class SelectionCoordinator {
    private let system: SystemProbing
    private let accessibility: AccessibilityReading
    private let clipboard: ClipboardCapturing

    /// A `var` on purpose: the user can edit the excluded apps in Settings
    /// while Everest is running, and a list frozen at construction goes stale
    /// in a way nobody notices until Everest reads from a password manager the
    /// user had explicitly excluded.
    public var excludedBundleIDs: [String]

    /// Chromium builds its tree in response to the attribute write, not before
    /// the call returns, so focus has to be re-resolved after a pause.
    private let manualAccessibilitySettle: Duration

    public init(
        system: SystemProbing,
        accessibility: AccessibilityReading,
        clipboard: ClipboardCapturing,
        excludedBundleIDs: [String],
        manualAccessibilitySettle: Duration = .milliseconds(100),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.system = system
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.excludedBundleIDs = excludedBundleIDs
        self.manualAccessibilitySettle = manualAccessibilitySettle
        self.now = now
    }

    /// Injected so cache expiry can be tested without a ten-minute sleep.
    private let now: () -> ContinuousClock.Instant

    private var cache = StrategyCache()

    /// Case-insensitive and exact. Deliberately not prefix or wildcard
    /// matching, which would let `com.apple` silently exclude every Apple app.
    private func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Rung 4, before any text is read and before any keystroke is posted.
    /// Rung 0 catches a password manager that has taken secure input; this
    /// catches a password field that has not, which is the normal case for a
    /// web or Electron password input — measured, those set the secure subrole
    /// and do *not* set the process-wide flag.
    private func refuseIfSecure(_ element: AXUIElement) throws {
        if accessibility.isSecure(element) { throw CaptureError.secureField }
    }

    public func capture() throws -> TargetSnapshot {
        let snapshot = try runCaptureChain()

        // One choke point, so a future rung cannot forget it. The length is
        // only knowable after the read, so this refuses to *proceed* rather
        // than refusing to look.
        let count = snapshot.text.count
        guard count <= CaptureLimits.maxCharacters else { throw CaptureError.tooLong(count) }
        return snapshot
    }

    private func runCaptureChain() throws -> TargetSnapshot {
        // Rung 0. Free, needs no permission, and true exactly when the user is
        // doing something we must stay out of. It is also the moment synthetic
        // keystrokes stop being delivered, so continuing would fail anyway.
        if system.isSecureEventInputEnabled() { throw CaptureError.secureField }

        guard let app = system.frontmostApp() else { throw CaptureError.noSelection }

        // Rung 2, before a single accessibility call is aimed at the app.
        if let bundleID = app.bundleID, isExcluded(bundleID) {
            throw CaptureError.excludedApp(bundleID)
        }

        // Rung 3. Everything past here needs it, including posting ⌘C.
        guard system.isAccessibilityTrusted() else {
            throw CaptureError.accessibilityNotGranted
        }

        // Rungs 3a and 4, on every capture, cached or not. Focus is resolved
        // here rather than inside the read because rung 4 needs an element to
        // inspect, and the apps most likely to hide a password field are
        // exactly the ones whose accessibility tree is off.
        //
        // Residual gap, stated so nobody assumes it is covered: an app that
        // exposes no tree at all gives us nothing to classify, so only the
        // process-wide flag applies there. The mitigation is the exclusion list.
        let focused = accessibility.focusedElement(pid: app.pid)
        if let focused { try refuseIfSecure(focused) }

        // Only now. The cache is allowed to skip *work*; it is never allowed to
        // skip a *refusal*. Moving this above `refuseIfSecure` reintroduces a
        // fixed bug in which a remembered clipboard app posted ⌘C at a web
        // password field, with only the process-wide flag in the way — and web
        // password fields do not set it.
        //
        // A cached answer is also a hint rather than a gate: if the remembered
        // route comes up empty we fall through and probe properly, so a stale
        // entry costs one wasted copy, never a permanent downgrade to a path
        // that can never be written back.
        var clipboardTried = false
        if cache.strategy(for: app.bundleID ?? "", appVersion: app.appVersion, now: now())
            == .clipboard
        {
            clipboardTried = true
            if let snapshot = readViaClipboard(app: app) { return snapshot }
        }

        if let focused, let snapshot = try readViaAccessibility(app: app, element: focused) {
            record(.accessibility, for: app)
            return snapshot
        }

        // Rung 8. Chromium and Electron keep the tree switched off until asked.
        // The tree is built in response to the write and is not ready when the
        // call returns, so focus is re-resolved from scratch after a settle.
        // Once, never in a loop: if it did not appear it is not going to, and
        // looping turns a failed capture into a visible freeze.
        accessibility.enableManualAccessibility(pid: app.pid)
        if manualAccessibilitySettle > .zero {
            Thread.sleep(forTimeInterval: manualAccessibilitySettle.timeInterval)
        }

        if let revealed = accessibility.focusedElement(pid: app.pid) {
            // The tree that just appeared may contain the secure field the
            // first pass could not see.
            try refuseIfSecure(revealed)
            if let snapshot = try readViaAccessibility(app: app, element: revealed) {
                record(.accessibility, for: app)
                return snapshot
            }
        }

        if !clipboardTried, let snapshot = readViaClipboard(app: app) {
            record(.clipboard, for: app)
            return snapshot
        }

        throw CaptureError.noSelection
    }

    private func record(_ strategy: CaptureStrategy, for app: FrontmostApp) {
        guard let bundleID = app.bundleID else { return }
        cache.record(strategy, for: bundleID, appVersion: app.appVersion, now: now())
    }

    /// Rung 9. No element, so no range and no text identity: such a snapshot
    /// can never be proved safe to write to and always ends in copy-only.
    private func readViaClipboard(app: FrontmostApp) -> TargetSnapshot? {
        guard let text = clipboard.copySelection(pid: app.pid), !text.isEmpty else {
            return nil
        }
        return TargetSnapshot(
            pid: app.pid,
            bundleID: app.bundleID,
            appVersion: app.appVersion,
            element: AXUIElementCreateApplication(app.pid),
            text: text,
            range: nil,
            role: nil,
            isEditable: false,
            isRangeDerived: false
        )
    }

    /// Rungs 5 through 7. Returns `nil` when the app answered nothing at all,
    /// which is the only state worth escalating past. A definite answer —
    /// a plainly empty selection — throws instead, because escalating that is
    /// how a stale clipboard gets rewritten.
    private func readViaAccessibility(app: FrontmostApp, element: AXUIElement) throws
        -> TargetSnapshot?
    {
        let range = accessibility.selectedRange(of: element)

        // Rung 6, read ahead of the text because it is the only thing that can
        // disambiguate an empty `AXSelectedText`, and because a zero-length
        // range is authoritative even when the text is non-empty. Reading it
        // early costs nothing: a range is not the user's characters.
        if let range, range.length == 0 { throw CaptureError.noSelection }

        // Rung 5. The app's own answer, preferred over anything reconstructed
        // from the range.
        let selected = accessibility.selectedText(of: element) ?? ""
        if !selected.isEmpty {
            return snapshot(
                app: app, element: element, text: selected,
                range: range, isRangeDerived: false
            )
        }

        // Rung 7. Several text engines implement the range and not the string.
        // Entered only when rung 5 came back empty, which is exactly the
        // population where preferring `AXSelectedText` offers no protection, so
        // this route fails closed downstream rather than being trusted.
        if let range, let reconstructed = accessibility.string(of: element, in: range),
            !reconstructed.isEmpty
        {
            return snapshot(
                app: app, element: element, text: reconstructed,
                range: range, isRangeDerived: true
            )
        }

        return nil
    }

    private func snapshot(
        app: FrontmostApp,
        element: AXUIElement,
        text: String,
        range: CFRange?,
        isRangeDerived: Bool
    ) -> TargetSnapshot {
        TargetSnapshot(
            pid: app.pid,
            bundleID: app.bundleID,
            appVersion: app.appVersion,
            element: element,
            text: text,
            range: range,
            role: accessibility.role(of: element),
            isEditable: accessibility.isEditable(element),
            isRangeDerived: isRangeDerived
        )
    }
}
