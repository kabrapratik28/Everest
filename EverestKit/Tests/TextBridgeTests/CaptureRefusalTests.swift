import ApplicationServices
import Testing

@testable import TextBridge

@Suite("Capture refusals")
struct CaptureRefusalTests {

    /// Measured: a real `NSSecureTextField` reports role `AXTextField` with
    /// subrole `AXSecureTextField`, and a web or Electron password input does
    /// not set the process-wide secure-input flag at all. A role-only check, or
    /// a flag-only check, reads the password.
    @Test("refuses a secure subrole even when the process-wide secure-input flag is false")
    func refusesSecureSubroleWhenGlobalFlagIsFalse() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.role = "AXTextField"
        ax.subrole = "AXSecureTextField"
        ax.selected = "hunter2"

        let coordinator = SelectionCoordinator(
            system: FakeSystem(secureInputEnabled: false),
            accessibility: ax,
            clipboard: FakeClipboardCapture(),
            excludedBundleIDs: []
        )

        #expect(throws: CaptureError.secureField) {
            _ = try coordinator.capture()
        }
        #expect(ax.textReads == 0, "the password must never be read")
    }

    /// Rung 8, and the reason this test exists is that deleting the guard it
    /// covers used to leave all 74 tests passing.
    ///
    /// On the Chromium and Electron path this re-check is the **only** thing
    /// in the way. Rung 0 does not fire: a web password input does not set
    /// the process-wide flag, which is measured and recorded in `AGENTS.md`.
    /// Rung 4 was skipped because there was no element to inspect — which is
    /// precisely why rung 8 ran at all. So the tree that `AXManualAccessibility`
    /// reveals is the first sight of the field, and the last chance to refuse
    /// before a password is read into a prompt.
    ///
    /// The fixture that reaches this guard was already in the suite, in
    /// `manualAccessibilityEnablesTheTreeAndRetriesOnce`; it just revealed an
    /// ordinary text field, so the one fixture able to exercise the guard was
    /// the one that never did.
    @Test("a secure field in the tree revealed by AXManualAccessibility is refused")
    func revealedTreeIsRecheckedForASecureField() throws {
        let ax = FakeAccessibility()
        ax.focused = nil  // Chromium, tree switched off
        let clipboard = FakeClipboardCapture()
        clipboard.result = "hunter2"

        ax.onEnableManualAccessibility = { [weak ax] in
            // The tree appears, and it is a password field.
            ax?.focused = testElement()
            ax?.role = "AXTextField"
            ax?.subrole = "AXSecureTextField"
            ax?.selected = "hunter2"
            ax?.range = CFRange(location: 0, length: 7)
        }

        let coordinator = SelectionCoordinator(
            system: FakeSystem(secureInputEnabled: false),
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: [],
            manualAccessibilitySettle: .zero
        )

        #expect(throws: CaptureError.secureField) {
            _ = try coordinator.capture()
        }
        #expect(ax.manualAccessibilityEnables == 1, "the tree really was revealed")
        #expect(ax.textReads == 0, "the password was never read")
        #expect(clipboard.attempts == 0, "and no ⌘C was posted at it")
    }

    /// Rung 0. The process-wide flag is what a native password field and a
    /// password manager set, and it costs nothing and needs no permission, so
    /// it is checked before the app is even identified.
    @Test("refuses while process-wide secure input is enabled, before resolving focus")
    func refusesWhileSecureInputEnabled() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.role = "AXTextField"
        ax.selected = "hunter2"

        let coordinator = SelectionCoordinator(
            system: FakeSystem(secureInputEnabled: true),
            accessibility: ax,
            clipboard: FakeClipboardCapture(),
            excludedBundleIDs: []
        )

        #expect(throws: CaptureError.secureField) {
            _ = try coordinator.capture()
        }
        #expect(ax.focusResolutions == 0)
        #expect(ax.textReads == 0)
    }

    /// The exclusion list is the user's own "stay out of this app". It is
    /// honoured before a single accessibility call is aimed at the app, so an
    /// excluded password manager is never even inspected.
    @Test("refuses an excluded bundle id before reading anything")
    func refusesExcludedBundleBeforeReadingAnything() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = "master password"
        let clipboard = FakeClipboardCapture()

        let coordinator = SelectionCoordinator(
            system: FakeSystem(
                frontmost: FrontmostApp(
                    pid: 501, bundleID: "com.1password.1password", appVersion: "8.0"
                )
            ),
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: ["com.1password.1password"]
        )

        #expect(throws: CaptureError.excludedApp("com.1password.1password")) {
            _ = try coordinator.capture()
        }
        #expect(ax.focusResolutions == 0)
        #expect(ax.textReads == 0)
        #expect(clipboard.attempts == 0)
    }

    /// Exact but case-insensitive. No prefix or wildcard matching: a user
    /// typing `com.apple` and silently excluding every Apple app would be a
    /// surprise nobody asked for.
    @Test("matches an excluded bundle id case-insensitively, but never by prefix")
    func exclusionMatchingIsCaseInsensitiveAndExact() throws {
        func coordinator(frontmost bundleID: String, excluding excluded: [String])
            -> SelectionCoordinator
        {
            let ax = FakeAccessibility()
            ax.focused = testElement()
            ax.selected = "text"
            ax.range = CFRange(location: 0, length: 4)
            return SelectionCoordinator(
                system: FakeSystem(
                    frontmost: FrontmostApp(pid: 501, bundleID: bundleID, appVersion: "1.0")
                ),
                accessibility: ax,
                clipboard: FakeClipboardCapture(),
                excludedBundleIDs: excluded
            )
        }

        #expect(throws: CaptureError.excludedApp("COM.Example.Editor")) {
            _ = try coordinator(
                frontmost: "COM.Example.Editor", excluding: ["com.example.editor"]
            ).capture()
        }
        #expect(throws: Never.self) {
            _ = try coordinator(frontmost: "com.example.editor", excluding: ["com.example"])
                .capture()
        }
    }

    /// Rung 3. Everything past this point needs the permission, including
    /// posting the synthetic keystroke, and the user can revoke it at any time.
    @Test("refuses when Accessibility permission is not granted, before touching the app")
    func refusesWithoutAccessibilityPermission() throws {
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = "some text"
        let clipboard = FakeClipboardCapture()

        let coordinator = SelectionCoordinator(
            system: FakeSystem(accessibilityTrusted: false),
            accessibility: ax,
            clipboard: clipboard,
            excludedBundleIDs: []
        )

        #expect(throws: CaptureError.accessibilityNotGranted) {
            _ = try coordinator.capture()
        }
        #expect(ax.focusResolutions == 0)
        #expect(clipboard.attempts == 0)
    }

    /// The character budget is a property of the capture, not of the engine:
    /// refusing here means the overlay can say why instead of the model
    /// quietly truncating the user's document.
    ///
    /// Driven on every route on purpose. The check sits at one choke point
    /// after the chain, so that a new rung cannot forget it — but a test that
    /// only ever arrives by rung 5 pins it to rung 5, and a refactor moving it
    /// into that branch would pass. Rungs 7 and 9 are the whole copy-only
    /// column of root §3: every terminal, every PDF, and Google Docs.
    @Test("input over the 8,000 character limit is refused whichever rung produced it",
          arguments: CaptureRoute.allCases)
    func refusesInputOverTheCharacterLimit(route: CaptureRoute) throws {
        let overLimit = String(repeating: "a", count: CaptureLimits.maxCharacters + 1)

        #expect(throws: CaptureError.tooLong(CaptureLimits.maxCharacters + 1)) {
            _ = try captureText(overLimit, via: route)
        }
    }

    @Test("input exactly at the limit is accepted")
    func acceptsInputExactlyAtTheLimit() throws {
        let atLimit = String(repeating: "a", count: CaptureLimits.maxCharacters)
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = atLimit
        ax.range = CFRange(location: 0, length: atLimit.count)

        let coordinator = SelectionCoordinator(
            system: FakeSystem(),
            accessibility: ax,
            clipboard: FakeClipboardCapture(),
            excludedBundleIDs: []
        )

        #expect(try coordinator.capture().text.count == CaptureLimits.maxCharacters)
    }
}
