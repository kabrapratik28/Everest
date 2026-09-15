import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The production `SystemProbing`. Pure translation over three system calls,
/// with no policy: the refusal order lives in `SelectionCoordinator` and the
/// safety gate in `TargetValidator`.
public struct SystemProbe: SystemProbing, Sendable {
    public init() {}

    /// A process-wide flag any app can set: password managers, the login
    /// window, Terminal's Secure Keyboard Entry.
    public func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// The **non-prompting** variant, deliberately. The shell decides when to
    /// ask for permission; a probe that prompted would throw a system dialog
    /// every time the user pressed the hotkey without it.
    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Needs no Accessibility permission, which is why app identity is
    /// established before anything that does.
    public func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appVersion: Self.version(of: app.bundleURL)
        )
    }

    /// A missing bundle, a missing key and an empty value all mean the same
    /// thing: this app did not tell us its version. They must all read as
    /// `nil`, because `StrategyCache` keys on bundle id plus version, and an
    /// empty string is not a version — handing one to the cache as though it
    /// were is a lie that compares equal to itself.
    static func version(of bundleURL: URL?) -> String? {
        guard let bundleURL, let bundle = Bundle(url: bundleURL),
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty
        else { return nil }
        return version
    }
}
