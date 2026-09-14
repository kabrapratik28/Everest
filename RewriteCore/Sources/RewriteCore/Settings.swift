import Combine
import Foundation

/// Persisted user preferences: which engine to use, the two editable
/// prompt configurations, and the apps this tool should never read from.
///
/// `UserDefaults`-backed so preferences survive relaunch with no extra
/// plumbing in the app target. See AGENTS.md for why persistence lives
/// here, in the pure package, rather than in the `Everest` app target.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @Published public var engineID: EngineID {
        didSet { store.set(engineID.rawValue, forKey: Keys.engineID) }
    }

    @Published public var quickImprove: Preset {
        didSet { store.setEncoded(quickImprove, forKey: Keys.quickImprove) }
    }

    @Published public var styles: [Preset] {
        didSet { store.setEncoded(styles, forKey: Keys.styles) }
    }

    @Published public var excludedBundleIDs: [String] {
        didSet { store.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    private let store: UserDefaults

    /// `store` defaults to `.standard`. Tests and previews can pass an
    /// isolated `UserDefaults(suiteName:)` instead so they never read or
    /// pollute the real user's saved preferences.
    public init(store: UserDefaults = .standard) {
        self.store = store

        if let raw = store.string(forKey: Keys.engineID), let restored = EngineID(rawValue: raw) {
            engineID = restored
        } else {
            engineID = .qwen4B
        }

        quickImprove = store.decoded(Preset.self, forKey: Keys.quickImprove) ?? .quickImprove
        styles = store.decoded([Preset].self, forKey: Keys.styles) ?? Preset.builtInStyles
        excludedBundleIDs =
            (store.array(forKey: Keys.excludedBundleIDs) as? [String])
            ?? AppSettings.defaultExcludedBundleIDs
    }

    /// Resets only the Quick Improve prompt to its shipped default. Does
    /// not touch `styles`, so a customized style list survives.
    public func resetQuickImprove() {
        quickImprove = .quickImprove
    }

    /// Best-effort defaults for apps this tool should never try to read a
    /// selection from, even before the per-capture secure-field check
    /// (Task 2) runs. User-editable from the Privacy settings tab.
    private static let defaultExcludedBundleIDs = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
    ]

    private enum Keys {
        static let engineID = "everest.settings.engineID"
        static let quickImprove = "everest.settings.quickImprove"
        static let styles = "everest.settings.styles"
        static let excludedBundleIDs = "everest.settings.excludedBundleIDs"
    }
}

extension UserDefaults {
    fileprivate func setEncoded<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }

    fileprivate func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
