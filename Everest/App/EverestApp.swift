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

    var body: some Scene {
        Settings {
            SettingsView(
                settings: AppSettings.shared,
                models: delegate.modelSettings,
                isAccessibilityTrusted: { SystemProbe().isAccessibilityTrusted() }
            )
        }
    }
}
