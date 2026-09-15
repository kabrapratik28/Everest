import AppKit

/// The menu bar item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let quickImprove: () -> Void
    private let chooseStyle: () -> Void
    private let openSettings: () -> Void
    private let openOnboarding: () -> Void

    init(
        quickImprove: @escaping () -> Void,
        chooseStyle: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openOnboarding: @escaping () -> Void
    ) {
        self.quickImprove = quickImprove
        self.chooseStyle = chooseStyle
        self.openSettings = openSettings
        self.openOnboarding = openOnboarding
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

        // No `keyEquivalent` on these two. The real bindings are global
        // `KeyboardShortcuts` hotkeys, and a menu key equivalent would be a
        // second, separately-editable copy that goes stale the moment the user
        // rebinds — showing ⌘I in the menu while the hotkey is ⌥R.
        menu.addItem(withTitleAction: "Quick Improve", target: self, action: #selector(runQuickImprove))
        menu.addItem(withTitleAction: "Choose Style…", target: self, action: #selector(runChooseStyle))
        menu.addItem(.separator())
        menu.addItem(withTitleAction: "Settings…", target: self, action: #selector(runOpenSettings))
        menu.addItem(withTitleAction: "Setup Guide…", target: self, action: #selector(runOpenOnboarding))
        menu.addItem(.separator())
        menu.addItem(withTitleAction: "Quit Everest", target: self, action: #selector(runQuit))
        return menu
    }

    @objc private func runQuickImprove() { quickImprove() }
    @objc private func runChooseStyle() { chooseStyle() }
    @objc private func runOpenSettings() { openSettings() }
    @objc private func runOpenOnboarding() { openOnboarding() }
    @objc private func runQuit() { NSApp.terminate(nil) }
}

private extension NSMenu {
    /// `addItem(withTitle:action:keyEquivalent:)` leaves `target` nil, which
    /// sends the action down the responder chain — and this app has no key
    /// window to start that chain, so every item would be permanently greyed
    /// out. Setting the target explicitly is what makes them clickable.
    func addItem(withTitleAction title: String, target: AnyObject, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        addItem(item)
    }
}
