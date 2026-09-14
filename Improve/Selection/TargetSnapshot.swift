import ApplicationServices
import Foundation

/// Everything we know about *where* a rewrite came from, captured at one instant.
///
/// A snapshot is a claim about the world that stops being true the moment the
/// user clicks somewhere else. It exists so that `ReplacementService` can prove,
/// immediately before it writes, that the world still matches the claim. Nothing
/// in here may be "helpfully" adjusted after capture: `text` in particular is the
/// exact bytes the app handed us.
///
/// `@unchecked Sendable` because `AXUIElement` is a CoreFoundation reference that
/// Swift cannot reason about. Every method that touches one is `@MainActor`, so
/// the element is only ever dereferenced on one thread. The snapshot itself is
/// immutable and is handed to the rewrite actor as a value.
struct TargetSnapshot: @unchecked Sendable {
    /// The process that owned the selection. Revalidated as "still frontmost".
    let pid: pid_t
    /// `nil` for processes without a bundle, such as a raw executable.
    let bundleID: String?
    /// `CFBundleShortVersionString` and `CFBundleVersion` joined. Part of the
    /// strategy cache key so that upgrading an app re-probes it from scratch.
    let appVersion: String?
    /// The focused accessibility element the text was read from.
    let element: AXUIElement
    /// The selected text, byte for byte as the app reported it. Never trimmed.
    let text: String
    /// UTF-16 style offsets, as reported by `AXSelectedTextRange`. `nil` when the
    /// app does not report a range, which happens on the clipboard capture path.
    let range: CFRange?
    /// `AXRole` of the focused element, used only for diagnostics and for the
    /// editability hint.
    let role: String?
    /// Best-effort hint that writing is possible at all. Over-reports on purpose;
    /// see `Improve/Replacement/AGENTS.md`.
    let isEditable: Bool
    /// Monotonic capture time. Deliberately *not* used as an expiry; see
    /// `TargetValidator`.
    let capturedAt: ContinuousClock.Instant

    /// True when `text` was reconstructed from `range` via `AXStringForRange`
    /// rather than reported directly by the app as `AXSelectedText`.
    ///
    /// Such a capture can never be written back. Chromium and Electron have a
    /// long standing off-by-one in `AXSelectedTextRange`, and this route is
    /// entered only when `AXSelectedText` was empty, which is exactly the
    /// population where that bug has no mitigation. The resulting text is well
    /// formed but may be shifted by a character, and revalidation is
    /// structurally unable to notice: it would re-read through the same
    /// shifted range, get the same shifted string, and agree with itself.
    /// `ReplacementService` refuses to write any snapshot with this set.
    ///
    /// This one field is an addition to the type as the MVP plan declares it,
    /// made in response to code review. It is a `var` with a default, unlike
    /// every other field here, for a mechanical reason worth knowing: a `let`
    /// with a default value is *excluded* from Swift's memberwise initializer,
    /// so it would have been permanently false and this guard would have been
    /// dead code that looked alive. `var` keeps it settable at construction
    /// while leaving the plan's initializer signature source compatible.
    /// Nothing mutates it after capture.
    var isRangeDerived: Bool = false
}

/// Why a capture produced nothing.
///
/// There is no "this app is opaque to us" case on purpose: the plan fixes this
/// enum, and an app that answers neither accessibility nor a synthetic copy is
/// indistinguishable from an app with nothing selected. Both surface as
/// `.noSelection`.
enum CaptureError: Error, Equatable {
    case accessibilityNotGranted, secureField, noSelection, tooLong(Int), excludedApp(String)
}

/// The result of trying to put a rewrite back.
///
/// `.copiedOnly` carries a promise: the rewritten text has been placed on the
/// general pasteboard so the user can paste it themselves. `ReplacementService`
/// never returns this case without keeping that promise.
///
/// Declared here rather than next to `ReplacementService` because the MVP plan
/// declares all three types in this file and the other tasks consume them
/// verbatim.
enum ReplaceOutcome: Equatable { case replaced, copiedOnly(reason: String) }

// MARK: - Limits

enum CaptureLimits {
    /// Hard input cap from the plan. Counted in `Character`s, which is what a
    /// person means by "characters", not UTF-16 units. Range arithmetic elsewhere
    /// uses UTF-16 because that is what the accessibility API speaks.
    static let maxInputCharacters = 8_000
}

// MARK: - Presentation helpers

extension CaptureError {
    /// A sentence fit to show a person. Kept next to the cases so the overlay
    /// never has to invent wording, and so no call site is tempted to print the
    /// raw enum, which would be meaningless to a user.
    var userMessage: String {
        switch self {
        case .accessibilityNotGranted:
            return "Everest needs Accessibility permission to read the selection."
        case .secureField:
            return "Everest does not read password fields."
        case .noSelection:
            return "Select some text first."
        case .tooLong(let count):
            return "That selection is \(count) characters. The limit is \(CaptureLimits.maxInputCharacters)."
        case .excludedApp(let bundleID):
            return "Everest is turned off in \(bundleID)."
        }
    }
}
