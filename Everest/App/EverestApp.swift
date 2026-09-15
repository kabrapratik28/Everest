import AppCore
import RewriteCore
import SwiftUI
// `SystemProbe` lives in TextBridge, beside the `SystemProbing` protocol it
// conforms to. AppCore briefly shipped a second copy; two public types with
// one name across two imported modules is ambiguous at the use site.
import TextBridge

/// The whole SwiftUI surface of a menu-bar app.
///
/// `LSUIElement` is true, so there is no main window and no Dock icon: the
/// `Settings` scene is the only window SwiftUI owns, and everything else hangs
/// off `AppDelegate`. Onboarding is a plain `NSWindow` rather than a second
/// scene, because a `Window` scene would restore itself on every launch after
/// the user has finished setting up.
@main
struct EverestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The only thing that can raise a `Settings` scene.
    ///
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is the recipe
    /// everywhere online and it is dead: on macOS 26.6.2 neither
    /// `showSettingsWindow:` nor `showPreferencesWindow:` is implemented by
    /// `NSApplication` or by SwiftUI's `AppKitApplication`. Worse, `sendAction`
    /// still returns `true` — something down the chain claims it — so the call
    /// site sees success and the user sees nothing. `OpenSettingsAction` is the
    /// supported replacement, and it can only be read from a SwiftUI scope.
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        // Handed to the delegate here because the status-item menu lives
        // there and has no SwiftUI scope of its own. The scene body runs
        // before `applicationDidFinishLaunching`, so it is always set by the
        // time any menu item can be clicked.
        delegate.presentSettings = { openSettings() }

        return Settings {
            SettingsView(
                settings: AppSettings.shared,
                models: delegate.modelSettings,
                presence: delegate.presence,
                isAccessibilityTrusted: { SystemProbe().isAccessibilityTrusted() },
                collisionCaution: { AppDelegate.collisionCaution() },
                shortcutCostNote: { AppDelegate.shortcutCostNote() }
            )
        }
    }
}
