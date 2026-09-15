import ApplicationServices
import Foundation

/// Everything needed to prove, later, that the thing we are about to write to
/// is still the thing we read from.
public struct TargetSnapshot: @unchecked Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let appVersion: String?
    public let element: AXUIElement
    public let text: String
    public let range: CFRange?
    public let role: String?
    public let isEditable: Bool

    /// True when `text` was reconstructed by `AXStringForRange` rather than
    /// handed over by the app. Such a snapshot is never written back.
    ///
    /// Declared with **no default** on purpose. A `let` with a default value is
    /// excluded from Swift's memberwise initializer, so every construction site
    /// would silently get the default, the flag could never be true, and the
    /// guard reading it would be dead code that looks alive. No default forces
    /// every call site to state which kind of read it performed.
    public let isRangeDerived: Bool

    public let capturedAt: ContinuousClock.Instant

    public init(
        pid: pid_t,
        bundleID: String?,
        appVersion: String?,
        element: AXUIElement,
        text: String,
        range: CFRange?,
        role: String?,
        isEditable: Bool,
        isRangeDerived: Bool,
        capturedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.element = element
        self.text = text
        self.range = range
        self.role = role
        self.isEditable = isEditable
        self.isRangeDerived = isRangeDerived
        self.capturedAt = capturedAt
    }
}

/// Three outcomes, because there are three genuinely different things that
/// can happen to a rewrite.
public enum ReplaceOutcome: Equatable, Sendable {
    /// Written into the target.
    case replaced

    /// Not written into the target, so it is on the clipboard instead. This
    /// case carries a promise: it is never returned without the text having
    /// been durably written to the pasteboard first.
    ///
    /// `cause` is for control flow, `reason` is the sentence shown to the
    /// user. They are separate because the reason is user-facing copy that
    /// will legitimately get reworded, and a caller in another module
    /// branching on that prose breaks silently when it does.
    case copiedOnly(cause: CopyOnlyCause, reason: String)

    /// Neither written into the target nor placed on the clipboard, because
    /// overwriting what is already on the clipboard would destroy something
    /// we could not put back. Nothing at all was touched, and the choice to
    /// overwrite is the user's.
    case heldForManualCopy(cause: HoldCause, reason: String)
}

/// Why a rewrite went to the clipboard instead of into the target. Only
/// causes a real path returns.
public enum CopyOnlyCause: Equatable, Sendable {
    /// A password field has focus, at capture or by the time we write.
    case secureField
    /// Accessibility permission was revoked mid-rewrite.
    case noAccessibility
    /// Captured through `AXStringForRange`, so the text may be shifted and
    /// revalidation cannot detect it.
    case rangeDerived
    /// The fingerprint moved: another app frontmost, focus elsewhere, or the
    /// range or text changed.
    case targetChanged
    /// The app never answered, so nothing could be proved either way. The
    /// permanent state for anything captured through the clipboard.
    case unverifiable
    /// There is no editable buffer behind the selection at all.
    case notEditable
    /// We pasted and the target did not take it.
    case pasteNotConsumed
}

/// Why nothing at all was touched.
public enum HoldCause: Equatable, Sendable {
    /// The clipboard holds something we could not copy, so overwriting it
    /// would be unrecoverable.
    case clipboardTooLarge
    /// Another rewrite is mid-transaction and holds the borrow.
    case clipboardBusy
}

public enum CaptureLimits {
    /// Refused at capture rather than at the engine, so the overlay can say
    /// why instead of the model silently truncating the user's document.
    public static let maxCharacters = 8_000
}

public enum CaptureError: Error, Equatable {
    case accessibilityNotGranted
    case secureField

    /// The app's own answer: an element that holds text reported none of it
    /// selected. A claim about the user, and safe to act on as one.
    case noSelection

    /// Ours: every rung came back empty, including ⌘C. Deliberately *not*
    /// folded into `.noSelection`, which would tell a user looking at text
    /// they have selected to go and select some text. Which of the two it was
    /// is exactly what could not be determined, and the sentence has to say so
    /// rather than pick one and send half the users to reselect forever.
    case nothingCaptured

    /// The clipboard could not be borrowed, so rung 9 never ran. Separate
    /// from `.nothingCaptured` because the app is fine and the clipboard is
    /// what is in the way: naming the app sends the user hunting for a
    /// permission that does not exist.
    case clipboardUnavailable

    case tooLong(Int)
    case excludedApp(String)
}
