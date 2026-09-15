import Foundation

/// Which rung last worked for an app. A hint, never a gate.
public enum CaptureStrategy: Equatable, Sendable {
    case accessibility
    case clipboard
}

/// Remembers the working route per app so a hostile app is not re-probed on
/// every hotkey press.
///
/// Keyed by bundle identifier with the version stored in the *value*, so a
/// version mismatch replaces the entry rather than adding a second one. The
/// cache therefore cannot grow without bound, and the stale reading is gone
/// rather than merely unreachable: what we learned was learned about a
/// different binary.
struct StrategyCache {
    /// Without expiry one bad reading pins an app to the clipboard path
    /// forever. An Electron app answers nothing until *something* enables its
    /// tree, and that something may have been a screen reader that has since
    /// quit. Self-healing matters more than the milliseconds it costs.
    static let reprobeInterval: Duration = .seconds(600)

    private struct Entry {
        let strategy: CaptureStrategy
        let appVersion: String?
        let learnedAt: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]

    func strategy(for bundleID: String, appVersion: String?, now: ContinuousClock.Instant)
        -> CaptureStrategy?
    {
        guard let entry = entries[bundleID] else { return nil }
        guard entry.appVersion == appVersion else { return nil }
        guard entry.learnedAt.duration(to: now) < Self.reprobeInterval else { return nil }
        return entry.strategy
    }

    mutating func record(
        _ strategy: CaptureStrategy,
        for bundleID: String,
        appVersion: String?,
        now: ContinuousClock.Instant
    ) {
        entries[bundleID] = Entry(strategy: strategy, appVersion: appVersion, learnedAt: now)
    }
}
