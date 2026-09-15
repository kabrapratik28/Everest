import ApplicationServices
import Foundation

@testable import TextBridge

/// A real `AXUIElement` we own. `AXUIElementCreateApplication` needs no
/// permission and no live app, and two calls for the same pid produce equal
/// but non-identical references, which is exactly the shape the production
/// `CFEqual` comparison has to cope with.
func testElement(pid: pid_t = 501) -> AXUIElement {
    AXUIElementCreateApplication(pid)
}

/// Which rung produced the text. Shared rather than private to one suite,
/// because a decision taken at the chain's choke point has to be proved on
/// every route: rung 5 is the app's own answer, and rungs 7 and 9 are the
/// entire copy-only column of root §3 — every terminal, every PDF, Google Docs.
enum CaptureRoute: CaseIterable { case selectedText, stringForRange, clipboard }

/// Captures `text` through a chosen rung, with the settle at zero so the
/// suite never sleeps.
func captureText(_ text: String, via route: CaptureRoute) throws -> TargetSnapshot {
    let ax = FakeAccessibility()
    let clipboard = FakeClipboardCapture()

    switch route {
    case .selectedText:
        ax.focused = testElement()
        ax.selected = text
        ax.range = CFRange(location: 0, length: text.utf16.count)
    case .stringForRange:
        ax.focused = testElement()
        ax.selected = ""
        ax.range = CFRange(location: 0, length: text.utf16.count)
        ax.stringForRange = text
    case .clipboard:
        clipboard.result = text
    }

    return try SelectionCoordinator(
        system: FakeSystem(),
        accessibility: ax,
        clipboard: clipboard,
        excludedBundleIDs: [],
        manualAccessibilitySettle: .zero
    ).capture()
}

/// A class, not a struct, so a test can change what the machine reports
/// between two captures — an app upgrading under a warm cache entry, say.
final class FakeSystem: SystemProbing {
    var secureInputEnabled: Bool
    var accessibilityTrusted: Bool
    var frontmost: FrontmostApp?

    init(
        secureInputEnabled: Bool = false,
        accessibilityTrusted: Bool = true,
        frontmost: FrontmostApp? = FrontmostApp(
            pid: 501, bundleID: "com.example.editor", appVersion: "1.0"
        )
    ) {
        self.secureInputEnabled = secureInputEnabled
        self.accessibilityTrusted = accessibilityTrusted
        self.frontmost = frontmost
    }

    func isSecureEventInputEnabled() -> Bool { secureInputEnabled }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func frontmostApp() -> FrontmostApp? { frontmost }
}

/// Records every read so a test can assert that a refusal happened *before*
/// anything was looked at, which is the whole point of the guards.
final class FakeAccessibility: AccessibilityReading, AccessibilityWriting {
    var focused: AXUIElement?
    var role: String?
    var subrole: String?
    var selected: String?
    var range: CFRange?
    var stringForRange: String?

    /// `AXNumberOfCharacters`. `nil` models an element that does not implement
    /// the attribute at all, which is the same state of knowledge as zero.
    var characters: Int?

    var editable = true

    private(set) var focusResolutions = 0
    private(set) var selectedTextReads = 0
    private(set) var rangeStringReads = 0
    private(set) var manualAccessibilityEnables = 0

    /// Any route by which the user's characters could have reached us.
    var textReads: Int { selectedTextReads + rangeStringReads }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        focusResolutions += 1
        return focused
    }

    func role(of element: AXUIElement) -> String? { role }
    func subrole(of element: AXUIElement) -> String? { subrole }

    func selectedText(of element: AXUIElement) -> String? {
        selectedTextReads += 1
        return selected
    }

    func selectedRange(of element: AXUIElement) -> CFRange? { range }

    func characterCount(of element: AXUIElement) -> Int? { characters }

    func string(of element: AXUIElement, in range: CFRange) -> String? {
        rangeStringReads += 1
        return stringForRange
    }

    /// Lets a test model the thing that makes this rung exist: the tree does
    /// not exist until the attribute is written, and then it does.
    var onEnableManualAccessibility: (() -> Void)?

    func enableManualAccessibility(pid: pid_t) {
        manualAccessibilityEnables += 1
        onEnableManualAccessibility?()
    }

    func isEditable(_ element: AXUIElement) -> Bool { editable }

    // MARK: - AccessibilityWriting

    var settable = true
    var writeSucceeds = true
    private(set) var writes: [String] = []

    func isSelectedTextSettable(_ element: AXUIElement) -> Bool { settable }

    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        writes.append(text)
        return writeSucceeds
    }
}

final class FakeCopyKeystroke: KeystrokeCopying {
    private(set) var copies = 0
    /// Models the *target app* answering the ⌘C by writing the pasteboard.
    var onCopy: (() -> Void)?

    func postCopy(pid: pid_t) {
        copies += 1
        onCopy?()
    }
}

final class FakeKeystroke: KeystrokePosting {
    private(set) var pastes = 0
    /// Lets a test model the target consuming the paste: the selection
    /// collapses to a caret, so range and text both change.
    var onPaste: (() -> Void)?

    func postPaste(pid: pid_t) {
        pastes += 1
        onPaste?()
    }
}

final class FakeClipboardCapture: ClipboardCapturing {
    var result: String?

    /// The user's clipboard holds something too large to put back, so the
    /// borrow is refused and ⌘C is never posted.
    var borrowRefused = false

    private(set) var attempts = 0

    func copySelection(pid: pid_t) -> ClipboardCapture {
        attempts += 1
        if borrowRefused { return .unavailable }
        guard let result else { return .nothingCopied }
        return .captured(result)
    }
}

/// Records the trail so a test can assert what was written down, rather than
/// that something was.
final class FakeTrace: Tracing {
    private(set) var events: [TraceEvent] = []
    func record(_ event: TraceEvent) { events.append(event) }
}
