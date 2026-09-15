import Combine
import Foundation

/// Drives first-run setup: permission, then honesty about what the app can do,
/// then the model, then one real rewrite.
@MainActor
public final class OnboardingModel: ObservableObject {
    public enum Step: Int, CaseIterable, Sendable {
        case accessibility
        case capabilities
        case model
        case tryIt
    }

    @Published public private(set) var step: Step

    /// Read live rather than stored, because the user grants the permission in
    /// another process while this window is open.
    private let isAccessibilityTrusted: @Sendable () -> Bool
    private let store: UserDefaults

    private enum Keys {
        static let step = "everest.onboarding.step"
        static let complete = "everest.onboarding.complete"
    }

    public init(
        store: UserDefaults = .standard,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool
    ) {
        self.store = store
        self.isAccessibilityTrusted = isAccessibilityTrusted
        // Resumed, not restarted. The window has a close button, so
        // abandoning setup partway is one click and entirely expected;
        // restarting at the permission step each time would put the model
        // step out of reach of anyone who ever closed it.
        step = Step(rawValue: store.integer(forKey: Keys.step)) ?? .accessibility
    }

    /// Whether the user has been all the way through.
    ///
    /// Recorded separately from the Accessibility permission, and it has to
    /// be. The launch check used to read the permission, so anyone who
    /// granted it before opening the guide counted as set up and never saw
    /// the model step — the one step that puts a model on disk. A TCC grant
    /// cannot tell you whether someone read the capability table or chose an
    /// engine; nothing but a record of finishing can.
    public var isComplete: Bool {
        store.bool(forKey: Keys.complete)
    }

    /// Called when the user presses Done. Closing the window does not.
    public func markComplete() {
        store.set(true, forKey: Keys.complete)
    }

    /// Whether the permission is granted right now. The view polls this to
    /// light up the button; `advance` does not trust it and asks again.
    public var isGranted: Bool { isAccessibilityTrusted() }

    public func advance() {
        // The gate, and the only one. Everything past here reads a selection,
        // so without the permission the capability table describes reads that
        // cannot happen and the test rewrite has nothing to read.
        //
        // Asked again here, not read from a stored flag: granting happens in
        // System Settings while this window is open, and a value captured at
        // launch leaves the gate shut after the user has done exactly what it
        // asked. The only way out of that is quitting an app they have not
        // finished setting up.
        if step == .accessibility, !isAccessibilityTrusted() { return }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        store.set(next.rawValue, forKey: Keys.step)
    }
}

public extension OnboardingModel {
    enum CaptureAbility: Sendable, Equatable {
        case yes
        case usually
        case never
    }

    enum ReplaceAbility: Sendable, Equatable {
        case inPlace
        case copyOnly
        case refused
    }

    struct Capability: Sendable, Equatable, Identifiable {
        public let context: String
        public let capture: CaptureAbility
        public let replace: ReplaceAbility
        public var id: String { context }
    }

    /// Root `AGENTS.md` §3, shown during setup rather than discovered later.
    ///
    /// "Works anywhere" is true of reading a selection and false of writing
    /// one. Meeting that limit for the first time in Ghostty, mid-sentence,
    /// with no warning, reads as a broken app; the same behaviour announced up
    /// front is a tool handing you the clipboard. The password row is the
    /// other half — that refusal is the app working, and a user who is not
    /// told will assume it failed and try somewhere less careful.
    /// Shown beside the capability table, and not optional.
    ///
    /// The excluded-app list is easy to mistake for the protection. It is not:
    /// matching is case-insensitive and **exact**, deliberately not prefix, so
    /// every entry is one native app — and banking on a Mac is overwhelmingly
    /// a browser tab, which no entry on any list will ever cover. What
    /// actually protects a web or Electron password field is the secure
    /// subrole check, which is also the *only* thing protecting it: those
    /// fields do not set the process-wide secure-input flag.
    ///
    /// A user who believes the list is the defence adds their bank's name to
    /// it, gets nothing, and never finds out.
    nonisolated static let exclusionCaveat = """
        Everest refuses secure fields before it reads them, and that is what protects a \
        password — including in a browser or an Electron app, where the excluded-app list \
        cannot reach. The list in Settings ▸ Privacy is a convenience for keeping Everest \
        out of whole native apps, not the thing standing between it and your passwords.
        """

    nonisolated static let capabilities: [Capability] = [
        Capability(context: "Native text fields and editors", capture: .yes, replace: .inPlace),
        Capability(context: "Browser text areas and rich editors", capture: .usually, replace: .inPlace),
        Capability(context: "VS Code, Cursor, Sublime, Xcode", capture: .usually, replace: .inPlace),
        Capability(context: "Slack, Discord, Mail, Messages", capture: .usually, replace: .inPlace),
        Capability(context: "Terminal, Ghostty, iTerm", capture: .usually, replace: .copyOnly),
        Capability(context: "PDFs and ordinary web prose", capture: .usually, replace: .copyOnly),
        Capability(context: "Password and secure fields", capture: .never, replace: .refused),
    ]
}
