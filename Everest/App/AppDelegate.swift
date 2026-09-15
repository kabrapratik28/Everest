import AppCore
import AppKit
import Overlay
import RewriteCore
import SwiftUI
import TextBridge
import os

/// Construction and wiring. No decisions.
///
/// Every branch this app makes lives in `AppCore`, where there is a test
/// runner. What is left here is building the real objects, connecting the
/// panel's three callbacks to the coordinator, and opening windows — and if a
/// condition ever appears below, it belongs in `AppCore` instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Subsystem from the bundle, never a literal: a drifting literal fails
    /// invisibly, because the app runs and `log stream` simply returns nothing.
    ///
    /// **Nothing selected or generated is ever logged.** `OSLog` persists to
    /// disk, which would defeat the only promise this app makes. State names
    /// and counts only.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Everest", category: "app")

    private let settings = AppSettings.shared
    private let probe = SystemProbe()
    private let panel = FloatingPanelController.live()
    private let pasteboard = NSPasteboard.general

    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyManager?
    private var onboarding: NSWindow?

    private lazy var accessibility = AXSelectionAdapter()
    private lazy var keystroke = SyntheticKeystroke()

    private lazy var selection = SelectionCoordinator(
        system: probe,
        accessibility: accessibility,
        clipboard: ClipboardSelectionAdapter(
            pasteboard: pasteboard,
            keystroke: keystroke
        ),
        excludedBundleIDs: settings.excludedBundleIDs
    )

    private lazy var replacement = ReplacementService(
        system: probe,
        accessibility: accessibility,
        keystroke: keystroke,
        pasteboard: pasteboard
    )

    private(set) lazy var modelSettings = ModelSettingsModel(
        settings: settings,
        engineFor: EngineFactory.live(for:)
    )

    private lazy var coordinator = RewriteCoordinator(
        panel: panel,
        settings: settings,
        // The exclusion list arrives per capture rather than being assigned
        // once, so an app the user excluded a moment ago is excluded now.
        // `excludedBundleIDs` is a `var` on `SelectionCoordinator` for this.
        capture: { [selection] excluded in
            selection.excludedBundleIDs = excluded
            return try selection.capture()
        },
        engineFor: EngineFactory.live(for:),
        apply: { [replacement] text, target in replacement.apply(text, to: target) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onCancel = { [coordinator] in Task { await coordinator.cancel() } }
        panel.onPickStyle = { [coordinator] preset in Task { await coordinator.pickStyle(preset) } }
        panel.onCopy = { [weak self] text in self?.copyToPasteboard(text) }

        statusItem = StatusItemController(
            quickImprove: { [coordinator] in Task { await coordinator.quickImprove() } },
            chooseStyle: { [coordinator] in Task { await coordinator.chooseStyle() } },
            openSettings: { [weak self] in self?.openSettings() },
            openOnboarding: { [weak self] in self?.showOnboarding() }
        )

        hotkeys = HotkeyManager(coordinator: coordinator)
        hotkeys?.register()

        warnAboutItalicOnce()

        // Setup is gated on the permission, so an ungranted app has nothing to
        // offer until onboarding has been through.
        if !probe.isAccessibilityTrusted() { showOnboarding() }

        log.info("launched")
    }

    /// The panel's copy button, which for `heldForManualCopy` is the user's
    /// only way to keep the rewrite. Dismissing afterwards is deliberate: that
    /// state never closes itself, and once the text is safely on the clipboard
    /// the panel has nothing left to protect.
    private func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        panel.dismiss()
    }

    private func warnAboutItalicOnce() {
        let notice = ShortcutNotice()
        guard
            let shortcut = HotkeyManager.quickImproveShortcut,
            let message = notice.warning(for: shortcut)
        else { return }

        let alert = NSAlert()
        alert.messageText = "Everest uses ⌘I"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        notice.markWarned()
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func showOnboarding() {
        if let onboarding {
            NSApp.activate(ignoringOtherApps: true)
            onboarding.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(isAccessibilityTrusted: { [probe] in probe.isAccessibilityTrusted() })
        let view = OnboardingView(
            model: model,
            models: modelSettings,
            settings: settings,
            requestAccessibility: { Self.openAccessibilitySettings() },
            finish: { [weak self] in
                self?.onboarding?.close()
                self?.onboarding = nil
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Everest"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        onboarding = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the exact pane, rather than `AXIsProcessTrustedWithOptions`'s
    /// prompt: that dialog offers a button which opens this pane anyway, and
    /// only appears once per app signature, so a user who dismissed it can
    /// never get it back.
    static func openAccessibilitySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
