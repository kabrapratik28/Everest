import Combine
import Foundation

/// Drives first-run setup: permission, then honesty about what the app can do,
/// then the model, then one real rewrite.
@MainActor
public final class OnboardingModel: ObservableObject {
    /// **Raw values are explicit and 1 is deliberately missing.** The step is
    /// persisted, so renumbering moves anyone mid-setup to the wrong screen:
    /// someone stored on 2 would resume on `tryIt` and never see the model
    /// step, which is the one that puts weights on disk. 1 was a capability
    /// table, removed because it asked a first-time user to read a
    /// seven-row grid before they had seen the app do anything. What it
    /// taught is still said where it is actually needed: the panel names the
    /// apps that hand back the clipboard at the moment it happens, and the
    /// website and README carry the full table.
    public enum Step: Int, CaseIterable, Sendable {
        case accessibility = 0
        case model = 2
        case tryIt = 3
    }

    @Published public private(set) var step: Step

    /// Read live rather than stored, because the user grants the permission in
    /// another process while this window is open.
    private let isAccessibilityTrusted: @Sendable () -> Bool
    /// Whether the engine the user has chosen can actually run right now:
    /// weights on disk, or an engine that needs none.
    private let isSelectedEngineReady: @MainActor @Sendable () -> Bool
    /// Whether a model download is in flight right now.
    ///
    /// Read live, like the permission. "Use and download" starts a transfer
    /// and leaves this screen usable, so without a gate the user reaches the
    /// practice step and the hotkey starts a *second* download of the same
    /// gigabytes — `LoadOnce` deduplicates the load, not the download.
    private let isPreparing: @MainActor @Sendable () -> Bool
    private let store: UserDefaults

    private enum Keys {
        static let step = "everest.onboarding.step"
        static let complete = "everest.onboarding.complete"
    }

    public init(
        store: UserDefaults = .standard,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool,
        isPreparing: @escaping @MainActor @Sendable () -> Bool = { false },
        isSelectedEngineReady: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isPreparing = isPreparing
        self.isSelectedEngineReady = isSelectedEngineReady
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

    /// Whether the guide opens on launch.
    ///
    /// **A revoked permission reopens a finished guide.** macOS binds
    /// Accessibility to the code signature, so anything that changes the
    /// signature takes the grant away: a rebuild with a different
    /// certificate, and the one that will hit every existing user at once,
    /// moving to a notarised Developer ID build. The switch in System
    /// Settings stays on while `AXIsProcessTrusted()` returns false, so the
    /// user has no reason to suspect the permission at all.
    ///
    /// **This is not the rule above, inverted.** Completion is still stored
    /// and still never *inferred from* the grant: a grant marks nothing
    /// complete, because it cannot say whether anyone chose an engine, and
    /// reading it that way once let people skip the model step. This is the
    /// other direction, a grant that has gone missing reopening a guide
    /// already marked finished, and the two can both hold.
    ///
    /// Static and parameterised so the four combinations can be driven
    /// without a machine whose TCC state a test can set.
    public static func opensAtLaunch(isComplete: Bool, isGranted: Bool) -> Bool {
        !isComplete || !isGranted
    }

    public var opensAtLaunch: Bool {
        Self.opensAtLaunch(isComplete: isComplete, isGranted: isGranted)
    }

    /// Sends a reopened guide back to the step that can fix the problem.
    ///
    /// The step is persisted so someone who walked away mid-setup resumes
    /// where they stopped. That is wrong here: resuming at the practice step
    /// tells a user to select text and press the shortcut when the shortcut
    /// cannot read anything.
    public func rewindForLostPermission() {
        step = .accessibility
        store.set(Step.accessibility.rawValue, forKey: Keys.step)
    }

    /// Whether Continue does anything from where the user is standing.
    ///
    /// One property, read by both the button's `disabled` and by `advance`,
    /// because the two answering separately is how the button came to be
    /// enabled on a step it could not leave: it pressed, nothing moved, and
    /// nothing said why.
    ///
    /// Every condition is asked live. Both of them are changed by something
    /// outside this window — the permission in System Settings, the download
    /// by finishing — and a value captured when the step opened leaves the
    /// button dead after the user has done exactly what it asked.
    public var canAdvance: Bool {
        switch step {
        case .accessibility:
            // Everything past here reads a selection, so without the
            // permission the practice rewrite has nothing to read.
            isAccessibilityTrusted()
        case .model:
            // **Both conditions, and they are not the same one.** In flight
            // is a race: "Use and download" leaves this screen usable, so
            // without the gate the user reaches the practice step and the
            // hotkey starts a *second* download of the same gigabytes —
            // `LoadOnce` deduplicates the load, not the download. Ready is
            // the other half: with nothing on disk at all, Continue led to
            // "select some text and press the shortcut" and the rewrite
            // failed on a missing model the user was never told to fetch.
            //
            // Requiring ready was refused once, on the grounds that it would
            // strand a failed download. It does not: the row shows its error
            // and offers a retry, and Apple's engine needs no download, so
            // selecting it is ready immediately. Stranding was the right
            // worry and the wrong conclusion — what actually stranded people
            // was arriving at a practice step with no model behind it.
            !isPreparing() && isSelectedEngineReady()
        case .tryIt:
            true
        }
    }

    /// Why Continue is held, or `nil` when it is not.
    ///
    /// A grey button with no explanation is the version of this screen that
    /// had to be replaced: pressing it did nothing and said nothing, so a
    /// running download, a failed one and a broken control all looked
    /// identical — and they want three different things from the user.
    ///
    /// The permission step needs no line. Its whole body is the instruction,
    /// and it already shows Granted or Waiting live.
    public var continueHint: String? {
        guard !canAdvance else { return nil }
        return switch step {
        case .model where isPreparing():
            "Continue once the download finishes."
        case .model:
            "Download a model to continue — Everest has nothing to rewrite with yet."
        default:
            nil
        }
    }

    public func advance() {
        guard canAdvance else { return }
        // `rawValue + 1` would stop dead at the gap left by the removed step.
        guard let here = Step.allCases.firstIndex(of: step),
              case let next = Step.allCases.index(after: here),
              next < Step.allCases.endIndex else { return }
        step = Step.allCases[next]
        store.set(step.rawValue, forKey: Keys.step)
    }
}

public extension OnboardingModel {
    /// What Everest does about passwords, and the one case it cannot see.
    ///
    /// It used to say "Password and secure fields are never read. Everest
    /// refuses before it looks." Both guards behind that are real — the
    /// `AXSecureTextField` subrole refusal, and `IsSecureEventInputEnabled`
    /// asked at the top of the capture chain and again immediately before a
    /// clipboard read — but neither reaches an app that exposes **no**
    /// accessibility tree *and* leaves the process-wide flag clear. There is
    /// no element to classify and no flag to see.
    ///
    /// Chrome 153 set the flag when it was measured, on 2026-09-06; nothing
    /// obliges an Electron host, a custom control or a later Chrome to. One
    /// host at one version was standing in for an invariant covering every
    /// app forever, and an external auditor quoted it back as evidence for a
    /// P0 that did not exist. **The behaviour is not the defect — the
    /// sentence was.** Making no-tree clipboard capture opt-in was considered
    /// and refused: it would disable Sublime, Google Docs and every terminal,
    /// which is the whole copy-only column of root §3.
    ///
    /// Leads with what is enforced, because the guards have earned it and a
    /// caveat that opens on doubt gets skipped.
    nonisolated static let passwordPromise = """
        Everest refuses any field macOS marks as a password, and stops entirely while macOS \
        reports that one is being typed — checked again in the moment before any read that \
        goes through the clipboard. What it has no way to recognise is an app exposing no \
        accessibility information that also leaves that signal unset: browsers and password \
        managers set it, a custom control might not. For an app you would rather it stayed \
        out of altogether, the excluded list in Settings ▸ Privacy does that.
        """

    /// Shown beside the excluded-app list, which is the easiest control here
    /// to mistake for the protection. It is not: matching is
    /// case-insensitive and **exact**, deliberately not prefix, so every
    /// entry is one native app — and banking on a Mac is overwhelmingly a
    /// browser tab, which no entry on any list will ever cover. A user who
    /// believes the list is the defence adds their bank's name to it, gets
    /// nothing, and never finds out.
    nonisolated static let exclusionCaveat = """
        Everest refuses secure fields before it reads them, and that is what protects a \
        password — including in a browser or an Electron app, where the excluded-app list \
        cannot reach. The list in Settings ▸ Privacy is a convenience for keeping Everest \
        out of whole native apps, not the thing standing between it and your passwords.
        """
}
