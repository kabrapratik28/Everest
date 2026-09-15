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
    @Test("input over the 8,000 character limit is refused with its own length")
    func refusesInputOverTheCharacterLimit() throws {
        let overLimit = String(repeating: "a", count: CaptureLimits.maxCharacters + 1)
        let ax = FakeAccessibility()
        ax.focused = testElement()
        ax.selected = overLimit
        ax.range = CFRange(location: 0, length: overLimit.count)

        let coordinator = SelectionCoordinator(
            system: FakeSystem(),
            accessibility: ax,
            clipboard: FakeClipboardCapture(),
            excludedBundleIDs: []
        )

        #expect(throws: CaptureError.tooLong(CaptureLimits.maxCharacters + 1)) {
            _ = try coordinator.capture()
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
