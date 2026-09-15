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

    /// Not an init parameter: the public initialiser is wired from the app
    /// target, which `swift test` never compiles, and a fourth break there
    /// costs more than it buys. Tests assign it; production never does.
    var trace: Tracing = OSLogTrace()

    /// Case-insensitive and exact. Deliberately not prefix or wildcard
    /// matching, which would let `com.apple` silently exclude every Apple app.
    private func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Rung 4, before any text is read and before any keystroke is posted.
    /// Rung 0 catches a password manager that has taken secure input; this
    /// catches a password field that has not.
    ///
    /// This comment used to say web and Electron password fields never set
    /// the process-wide flag. Measured against Chrome 153, that is wrong —
    /// it sets it for `<input type=password>`. The subrole check is still
    /// what to rely on, because that flag is Chrome-the-app's doing and no
    /// other Chromium host is obliged to match it; the two guards are
    /// independent rather than one covering for the other.
    private func refuseIfSecure(_ element: AXUIElement) throws {
        if accessibility.isSecure(element) { throw CaptureError.secureField }
    }

    public func capture() throws -> TargetSnapshot {
        let snapshot: TargetSnapshot
        do {
            snapshot = try runCaptureChain()
        } catch let error as CaptureError {
            trace.record(.captureRefused(error))
            throw error
        }
        trace.record(
            .captured(
                rung: snapshot.viaClipboard
                    ? .clipboard : (snapshot.isRangeDerived ? .stringForRange : .selectedText),
                length: snapshot.text.count,
                hasRange: snapshot.range != nil,
                isEditable: snapshot.isEditable,
                isRangeDerived: snapshot.isRangeDerived,
                role: snapshot.role))

        // One choke point, so a future rung cannot forget it. The length is
        // only knowable after the read, so this refuses to *proceed* rather
        // than refusing to look.
        let count = snapshot.text.count
        guard count <= CaptureLimits.maxCharacters else {
            trace.record(.captureRefused(.tooLong(count)))
            throw CaptureError.tooLong(count)
        }
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
        // password field, with only the process-wide flag in the way — and
        // that flag is per-host, not guaranteed: Chrome 153 sets it, nothing
        // obliges an Electron app to.
        //
        // A cached answer is also a hint rather than a gate: if the remembered
        // route comes up empty we fall through and probe properly, so a stale
        // entry costs one wasted copy, never a permanent downgrade to a path
        // that can never be written back.
        var clipboardTried = false
        // Survives the whole chain: the borrow can be refused on the cached
        // attempt and the accessibility rungs can then fail on their own, and
        // what the user still needs told is that their clipboard is in the way.
        var clipboardRefused = false
        // Only while the app is still dark. The entry is recorded *only* when
        // focus did not resolve, so focus resolving now is that same signal
        // saying the reading has passed its sell-by. Without this the entry
        // is self-sustaining: a cached hit returns before accessibility is
        // asked, so the route that would replace it never runs, and an app
        // whose tree came back stays copy-only for the rest of the interval.
        // The existing fall-through does not cover it — that only rescues an
        // app whose clipboard route stopped working, not one where both work.
        if focused == nil,
            cache.strategy(for: app.bundleID ?? "", appVersion: app.appVersion, now: now())
                == .clipboard
        {
            clipboardTried = true
            if let snapshot = try readViaClipboard(app: app, refused: &clipboardRefused) {
                return snapshot
            }
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

        if !clipboardTried,
            let snapshot = try readViaClipboard(app: app, refused: &clipboardRefused)
        {
            // Remembered only for an app that stayed dark. The cache is keyed
            // by app and an app is not one text engine: Chrome is one bundle
            // identifier for Google Docs, readable only through ⌘C, and for
            // Gmail, which can be written back in place. Learning ⌘C from
            // Docs would cost Gmail its in-place rewrite for the next ten
            // minutes, a downgrade nobody can see or undo. What the cache is
            // for is skipping the re-proof that an app answers nothing, and
            // an app that resolved focus on the first ask is not that app.
            if focused == nil { record(.clipboard, for: app) }
            return snapshot
        }

        // The app was never the problem: ⌘C was never posted, because the
        // clipboard holds something we could not have put back afterwards.
        // Reporting the app sends them hunting for a permission that does not
        // exist, when what fixes it is copying something smaller.
        if clipboardRefused { throw CaptureError.clipboardUnavailable }

        // Not `.noSelection`. Nothing along the way told us the user had made
        // no selection; we simply ran out of ways to ask, and an app that
        // answers nothing over accessibility *and* copies nothing on ⌘C has
        // left us unable to tell an empty selection from text we cannot
        // reach. Saying "select some text" here picks one of those and sends
        // the other half of the users to reselect forever.
        throw CaptureError.nothingCaptured
    }

    private func record(_ strategy: CaptureStrategy, for app: FrontmostApp) {
        guard let bundleID = app.bundleID else { return }
        cache.record(strategy, for: bundleID, appVersion: app.appVersion, now: now())
    }

    /// Rung 9. No element, so no range and no text identity: such a snapshot
    /// can never be proved safe to write to and always ends in copy-only.
    private func readViaClipboard(app: FrontmostApp, refused: inout Bool) throws -> TargetSnapshot?
    {
        // Rung 0 again, at the moment it matters. It was asked at the top of
        // the chain; between then and here sit the `AXManualAccessibility`
        // write and its settle, and the user can click into a password field
        // in that time. This is also the one rung with no element to inspect,
        // so the subrole refusal cannot cover it — the process-wide flag is
        // all there is, and asking it once at the start is asking it about a
        // different moment.
        if system.isSecureEventInputEnabled() { throw CaptureError.secureField }

        let capture = clipboard.copySelection(pid: app.pid)
        if capture == .unavailable { refused = true }
        guard case let .captured(text) = capture, !text.isEmpty else { return nil }
        return TargetSnapshot(
            pid: app.pid,
            bundleID: app.bundleID,
            appVersion: app.appVersion,
            element: AXUIElementCreateApplication(app.pid),
            text: text,
            range: nil,
            role: nil,
            isEditable: false,
            isRangeDerived: false,
            viaClipboard: true
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
        //
        // What it is authoritative *about* is this element, and only that. An
        // element holding characters and reporting none of them selected is
        // the app saying plainly there is nothing to rewrite. An element
        // holding none at all cannot be the one the selection lives in — see
        // the canvas fact in `AGENTS.md` — so the honest reading there is "ask
        // the next rung", not "stop". A *missing* count is not a zero one.
        //
        // Neither branch reads anything beside the range: non-empty
        // `AXSelectedText` next to a zero-length range is a contradiction, and
        // text reconstructed through a zero-length range is not a selection.
        if let range, range.length == 0 {
            guard accessibility.characterCount(of: element) == 0 else {
                throw CaptureError.noSelection
            }
            return nil
        }

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
            isRangeDerived: isRangeDerived,
            viaClipboard: false
        )
    }
}
