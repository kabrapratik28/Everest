import Foundation
import Combine

/// UserDefaults-backed app settings. See RewriteCore/AGENTS.md: importing
/// Combine here (not AppKit/SwiftUI) keeps this package headless-testable —
/// ObservableObject and @Published impose no GUI requirement.
///
/// `init(store:)` takes an injectable store so tests and SwiftUI previews
/// never touch, or get polluted by, the real user's UserDefaults.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @Published public var engineID: EngineID {
        didSet { store.set(engineID.rawValue, forKey: Keys.engineID) }
    }
    @Published public var quickImprove: Preset {
        didSet { save(quickImprove, forKey: Keys.quickImprove) }
    }
    @Published public var styles: [Preset] {
        didSet { save(styles, forKey: Keys.styles) }
    }
    @Published public var excludedBundleIDs: [String] {
        didSet { store.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    /// Post the paste ourselves where Everest cannot write in place, instead
    /// of leaving the rewrite on the clipboard and asking for ⌘V.
    ///
    /// Read fresh per transaction and handed to `ReplacementService` as a
    /// parameter, never closed over — the `excludedBundleIDs` rule, for the
    /// same reason: a value frozen at launch goes stale the moment the user
    /// changes it and nothing tells them.
    @Published public var replacesAutomatically: Bool {
        didSet { store.set(replacesAutomatically, forKey: Keys.replacesAutomatically) }
    }

    /// Mark each rewrite `org.nspasteboard.TransientType` so clipboard
    /// managers skip it. A convention they honour, not something macOS
    /// enforces — see `ReplacementCopy.historyCaveat`, which says so.
    @Published public var keepsOutOfClipboardHistory: Bool {
        didSet { store.set(keepsOutOfClipboardHistory, forKey: Keys.keepsOutOfClipboardHistory) }
    }

    private let store: UserDefaults

    private enum Keys {
        static let engineID = "everest.settings.engineID"
        static let quickImprove = "everest.settings.quickImprove"
        static let styles = "everest.settings.styles"
        static let excludedBundleIDs = "everest.settings.excludedBundleIDs"
        static let replacesAutomatically = "everest.settings.replacesAutomatically"
        static let keepsOutOfClipboardHistory = "everest.settings.keepsOutOfClipboardHistory"
    }

    public init(store: UserDefaults = .standard) {
        self.store = store

        if let rawEngineID = store.string(forKey: Keys.engineID), let engineID = EngineID(rawValue: rawEngineID) {
            self.engineID = engineID
        } else {
            self.engineID = .qwen4B
        }

        self.quickImprove = Self.load(Preset.self, from: store, forKey: Keys.quickImprove) ?? .quickImprove
        self.styles = Self.load([Preset].self, from: store, forKey: Keys.styles) ?? Preset.builtInStyles
        // A coarse, defense-in-depth layer behind Selection's per-capture
        // secure-field check, not a security boundary on its own. See
        // RewriteCore/AGENTS.md.
        // Matching is case-insensitive and EXACT, never a prefix, so "com.apple"
        // cannot silently exclude every Apple app. Each entry is a full bundle id.
        //
        // Deliberately password managers only, and deliberately short. Banking
        // and brokerage happen in a browser far more often than in a native app,
        // and a bundle-id list does nothing for a web page — that case is covered
        // by the secure-subrole check, which is the actual defence. A longer list
        // of unverifiable ids would imply coverage this does not have.
        self.excludedBundleIDs = store.array(forKey: Keys.excludedBundleIDs) as? [String] ?? [
            "com.agilebits.onepassword7",
            "com.1password.1password",
            "com.lastpass.LastPass",
            "com.apple.keychainaccess",
            "com.apple.Passwords",      // verified present on macOS 26
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.dashlane.Dashlane",
        ]

        self.replacesAutomatically = Self.flag(store, Keys.replacesAutomatically, default: true)
        self.keepsOutOfClipboardHistory = Self.flag(store, Keys.keepsOutOfClipboardHistory, default: true)
    }

    /// `bool(forKey:)` answers `false` for a key that was never written, so
    /// it cannot distinguish "unset" from "the user turned this off" — and
    /// both of these default **on**. `object(forKey:)` is the only thing that
    /// can, so the default is applied on absence alone and a stored `false`
    /// survives every relaunch.
    private static func flag(_ store: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
    }

    public func resetQuickImprove() {
        quickImprove = .quickImprove
    }

    private static func load<T: Decodable>(_ type: T.Type, from store: UserDefaults, forKey key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }
}
