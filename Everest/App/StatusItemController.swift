import AppCore
import AppKit

/// The menu bar item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let quickImprove: () -> Void
    private let chooseStyle: () -> Void
    private let openSettings: () -> Void
    private let openOnboarding: () -> Void
    private let checkForUpdates: () -> Void
    private let shortcutText: @MainActor (Hotkey) -> String?

    /// Every item that could carry a shortcut, with the command it runs.
    /// Kept so `menuWillOpen` can re-read all of them without rebuilding.
    private var commandItems: [(item: NSMenuItem, command: MenuCommand)] = []

    init(
        quickImprove: @escaping () -> Void,
        chooseStyle: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openOnboarding: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        shortcutText: @escaping @MainActor (Hotkey) -> String?
    ) {
        self.quickImprove = quickImprove
        self.chooseStyle = chooseStyle
        self.openSettings = openSettings
        self.openOnboarding = openOnboarding
        self.checkForUpdates = checkForUpdates
        self.shortcutText = shortcutText
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.button?.image = Self.icon()
        item.button?.setAccessibilityLabel("Everest")
        item.menu = buildMenu()
    }

    /// A **template** SF Symbol, never `AppIcon.icns`.
    ///
    /// The app icon is a gradient painting. At 18pt it turns to mush, and a
    /// fixed-colour image cannot follow the menu bar between light and dark
    /// appearance or invert when the item is highlighted — it stays a dark
    /// smudge on a dark bar. `isTemplate = true` hands the tinting to AppKit,
    /// which is the only thing that gets all three right. See
    /// `Everest/Resources/AGENTS.md`.
    ///
    /// `sparkles` is the fallback for a deployment target without
    /// `mountain.2.fill`; a nil image would leave an invisible, unclickable
    /// item in the menu bar.
    private static func icon() -> NSImage? {
        let image = NSImage(systemSymbolName: "mountain.2.fill", accessibilityDescription: "Everest")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Everest")
        image?.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // No `keyEquivalent` for a *recordable* binding: that would be a
        // second, separately-editable copy which goes stale the moment the
        // user re-records. Those get a badge instead, re-read from
        // `KeyboardShortcuts` on every open, so it cannot disagree with the
        // hotkey actually registered. `⌘,` on Settings is the exception and
        // a real equivalent — a fixed convention cannot drift, and while
        // this menu is open Everest is handling events, so it fires.
        add(.quickImprove, "Quick Improve", #selector(runQuickImprove), to: menu)
        add(.chooseStyle, "Choose Style…", #selector(runChooseStyle), to: menu)
        menu.addItem(.separator())
        add(.settings, "Settings…", #selector(runOpenSettings), to: menu)
        add(.setupGuide, "Setup Guide…", #selector(runOpenOnboarding), to: menu)
        // Sparkle's own `SPUStandardUpdaterController` would install a menu
        // item for us, but only into an app menu — which an `LSUIElement`
        // app does not have. This dropdown is the only menu Everest owns.
        add(.checkForUpdates, "Check for Updates…", #selector(runCheckForUpdates), to: menu)
        menu.addItem(.separator())
        add(.quit, "Quit Everest", #selector(runQuit), to: menu)
        return menu
    }

    /// Re-reads every binding as the menu comes down.
    ///
    /// Here rather than in `buildMenu` because the menu is built once at
    /// launch and the user can re-record a hotkey at any point after that.
    /// Which commands are eligible is `MenuCommand.hotkey`, in `AppCore`,
    /// where it has a test; this only renders the answer.
    func menuWillOpen(_ menu: NSMenu) {
        for (item, command) in commandItems {
            item.badge = command.hotkey
                .flatMap(shortcutText)
                .map { NSMenuItemBadge(string: $0) }
        }
    }

    /// `addItem(withTitle:action:keyEquivalent:)` leaves `target` nil, which
    /// sends the action down the responder chain — and this app has no key
    /// window to start that chain, so every item would be permanently greyed
    /// out. Setting the target explicitly is what makes them clickable.
    private func add(_ command: MenuCommand, _ title: String, _ action: Selector, to menu: NSMenu) {
        // A real key equivalent only where `MenuCommand` says there is a
        // fixed convention — `⌘,` — never for a recordable hotkey, which
        // gets the badge instead. `NSMenuItem` defaults the modifier mask to
        // `.command`, so "," is ⌘,.
        let item = NSMenuItem(title: title, action: action, keyEquivalent: command.fixedKeyEquivalent ?? "")
        item.target = self
        menu.addItem(item)
        commandItems.append((item, command))
    }

    @objc private func runQuickImprove() { quickImprove() }
    @objc private func runChooseStyle() { chooseStyle() }
    @objc private func runOpenSettings() { openSettings() }
    @objc private func runOpenOnboarding() { openOnboarding() }
    @objc private func runCheckForUpdates() { checkForUpdates() }
    @objc private func runQuit() { NSApp.terminate(nil) }
}
