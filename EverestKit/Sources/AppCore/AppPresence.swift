import AppKit
import Combine
import Foundation

/// Whether Everest is a menu-bar app or an ordinary one.
///
/// There is no separate "appear in ⌘Tab" switch on macOS. ⌘Tab membership,
/// the Dock icon and owning the menu bar are one thing — the activation
/// policy — so the honest offer is `.regular` or `.accessory` and the label on
/// the toggle has to name the Dock icon too. Measured on macOS 26.6.2:
/// `setActivationPolicy` moves between the two at runtime in both directions
/// and sticks, so nothing here needs a relaunch.
///
/// Kept out of `AppSettings`, which is `RewriteCore`'s: prompts, validation,
/// presets and the model catalog have no business knowing how the app shows
/// itself to the window server. `ShortcutNotice` already keeps app-shell state
/// in its own `UserDefaults` for the same reason.
@MainActor
public final class AppPresence: ObservableObject {
    /// `true` puts Everest in the Dock and the app switcher.
    ///
    /// Off by default, which is what a menu-bar app should be and also what
    /// `LSUIElement` already does — so a user who never finds this switch gets
    /// exactly the app they had.
    @Published public var showsInDockAndSwitcher: Bool {
        didSet { apply() }
    }

    private static let key = "everest.presence.showsInDockAndSwitcher"
    private let store: UserDefaults
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    public init(
        store: UserDefaults = .standard,
        setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void
    ) {
        self.store = store
        self.setPolicy = setPolicy
        // Property observers do not run for the initial value, which is what
        // keeps construction free of side effects: nothing moves the policy
        // until `start()`.
        showsInDockAndSwitcher = store.bool(forKey: Self.key)
    }

    /// Applies the stored preference. Call once, at launch.
    ///
    /// Not optional and not an optimisation. `LSUIElement` is `true` in
    /// Info.plist, so every launch begins at `.accessory` whatever the user
    /// chose last time; without this the switch turns itself off overnight and
    /// looks broken rather than unset.
    public func start() {
        apply()
    }

    private func apply() {
        store.set(showsInDockAndSwitcher, forKey: Self.key)
        setPolicy(showsInDockAndSwitcher ? .regular : .accessory)
    }
}
