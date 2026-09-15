import AppCore
import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
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

    /// Assigned by `EverestApp`'s scene body, which is the only scope that can
    /// read `OpenSettingsAction`. Set before launch finishes, so by the time
    /// the menu can be clicked it is there.
    var presentSettings: (@MainActor () -> Void)?

    private(set) lazy var presence = AppPresence(
        setPolicy: { _ = NSApp.setActivationPolicy($0) }
    )

    /// One instance, so the launch check and the window agree about which
    /// step the user is on and reopening resumes rather than restarts.
    private lazy var onboardingModel = OnboardingModel(
        isAccessibilityTrusted: { [probe] in probe.isAccessibilityTrusted() },
        // Continue stays shut while a transfer is running, or the practice
        // step's hotkey starts a second download of the same weights.
        isPreparing: { [weak self] in self?.modelSettings.isPreparing ?? false }
    )

    private lazy var accessibility = AXSelectionAdapter()
    private lazy var keystroke = SyntheticKeystroke()

    /// One adapter, shared by the read and the write paths.
    ///
    /// It is configuration only — no mutable state — and its pasteboard lock
    /// is `PasteboardBorrow.shared` either way, so a second instance would
    /// coordinate identically and mean nothing. Hoisted out of `selection`
    /// because `ReplacementService` now needs it too: the Sublime paste path
    /// re-reads the selection to verify the target before pasting into it.
    private lazy var clipboard = ClipboardSelectionAdapter(
        pasteboard: pasteboard,
        keystroke: keystroke
    )

    private lazy var selection = SelectionCoordinator(
        system: probe,
        accessibility: accessibility,
        clipboard: clipboard,
        excludedBundleIDs: settings.excludedBundleIDs
    )

    private lazy var replacement = ReplacementService(
        system: probe,
        accessibility: accessibility,
        keystroke: keystroke,
        clipboard: clipboard,
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
        // Both flags arrive as arguments and are forwarded unchanged. The
        // coordinator reads them inside the transaction, so nothing here
        // holds a value that could go stale — the `excludedBundleIDs` rule.
        apply: { [replacement] text, target, autoReplace, keepOutOfHistory in
            replacement.apply(
                text,
                to: target,
                autoReplace: autoReplace,
                keepOutOfHistory: keepOutOfHistory
            )
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `LSUIElement` pins every launch to `.accessory`, so the stored
        // preference has to be re-applied here or it silently resets.
        presence.start()

        // `engineID` comes straight out of `UserDefaults` and goes straight
        // to the coordinator, so it has met no gate: the disabled row is a
        // view and does not exist yet. A 30B choice restored onto a machine
        // that cannot hold it would load 17.2 GB on every hotkey press.
        settings.engineID = EngineEligibility.resolved(
            settings.engineID,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )

        panel.onCancel = { [coordinator] in Task { await coordinator.cancel() } }
        panel.onPickStyle = { [coordinator] preset in Task { await coordinator.pickStyle(preset) } }
        panel.onCopy = { [weak self] text in self?.copyToPasteboard(text) ?? false }

        statusItem = StatusItemController(
            quickImprove: { [coordinator] in Task { await coordinator.quickImprove() } },
            chooseStyle: { [coordinator] in Task { await coordinator.chooseStyle() } },
            openSettings: { [weak self] in self?.openSettings() },
            openOnboarding: { [weak self] in self?.showOnboarding() },
            shortcutText: { HotkeyManager.rendered($0) }
        )

        hotkeys = HotkeyManager(coordinator: coordinator)
        hotkeys?.register()

        warnAboutItalicOnce()

        // Gated on having *finished* setup, not on the permission. Reading
        // the permission counted anyone who granted Accessibility before
        // opening the guide as set up, so they never saw the model step — the
        // one step that puts a model on disk.
        if !onboardingModel.isComplete { showOnboarding() }

        log.info("launched")
    }

    /// The panel's copy button, which for `heldForManualCopy` is the user's
    /// only way to keep the rewrite.
    ///
    /// **Reports a read-back, and does not dismiss.** `Overlay.copy()` owns
    /// the dismissal now and does it only on `true`, so the panel closes on
    /// evidence the text is on the clipboard rather than on having tried —
    /// and the state this serves is the one holding the user's only copy.
    /// Dismissing here as well would put it back on the attempt.
    ///
    /// `setString` rather than `writeObjects`, which throws and would leave
    /// an error to swallow. The read-back narrows the overwrite window
    /// without closing it: another app writing *different* text between the
    /// two calls makes this return false, which keeps the panel up — the
    /// safe direction. `changeCount` would also catch a rewrite to the same
    /// value, which costs the user nothing, so it is not worth the state.
    private func copyToPasteboard(_ text: String) -> Bool {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.string(forType: .string) == text
    }

    private func warnAboutItalicOnce() {
        let notice = ShortcutNotice()
        guard
            let shortcut = HotkeyManager.quickImproveShortcut,
            let message = notice.warning(for: shortcut)
        else { return }

        let alert = NSAlert()
        // Safe to name the chord here: `warning` returns non-nil only for
        // exactly ⌘I, so whenever this alert is built that *is* the binding.
        // Everywhere the shortcut is merely described, it is rendered live.
        alert.messageText = "Everest uses ⌘I"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        notice.markWarned()
    }

    /// The caution for the Quick Improve binding as it stands right now.
    ///
    /// Composed here because `HotkeyManager` is the only thing that can read
    /// the live binding and `ShortcutNotice` is the only thing that decides
    /// whether it collides. Unlike `warnAboutItalicOnce`, this is not gated on
    /// having been said before: it describes what is in the recorder, so it
    /// has to be true every time the recorder is looked at.
    static func collisionCaution() -> String? {
        guard var shortcut = HotkeyManager.quickImproveShortcut else { return nil }
        if let live = KeyboardShortcuts.getShortcut(for: .quickImprove), translate(live).isDeadKey {
            shortcut = ShortcutNotice.Shortcut(
                key: shortcut.key,
                command: shortcut.command,
                shift: shortcut.shift,
                option: shortcut.option,
                control: shortcut.control,
                isDeadKey: true
            )
        }
        return ShortcutNotice.caution(for: shortcut)
    }

    /// Which character the Quick Improve binding costs, or nil.
    ///
    /// Separate from `collisionCaution` because it is information rather
    /// than a problem: `⌥R` is the default *because* `®` is a cheaper loss
    /// than Italic, and styling that as a warning would report the reason
    /// for the choice as a fault.
    static func shortcutCostNote() -> String? {
        guard let live = KeyboardShortcuts.getShortcut(for: .quickImprove) else { return nil }
        return ShortcutNotice.characterCost(for: translate(live).character)
    }

    /// What the **active keyboard layout** makes of a chord: the character
    /// it uniquely types, and whether it starts an accent instead.
    ///
    /// One call answers both, because they are one question — and a second
    /// mechanism answering half of it would hide the absence of a test for
    /// the first (root §1).
    ///
    /// Measured, never inferred from the letter. `⌥I` is dead on US and
    /// ordinary elsewhere, and `⌥R` types `®` only on layouts where Option
    /// composes — the same reason shortcut *rendering* lives in this target.
    ///
    /// `UCKeyTranslate` reports a dead key by producing no characters and
    /// leaving a non-zero `deadKeyState`, called with a zeroed state so the
    /// answer is about this chord alone and not about what preceded it.
    ///
    /// **`character` is nil unless the chord produces something the key
    /// alone does not.** Measured: `⌘R` translates to `"r"` and `⌘I` to
    /// `"i"`, because Command does not compose characters — reporting those
    /// as a cost would tell the user they can no longer type `r`, which is
    /// false and alarming. Control characters are excluded for the same
    /// reason: `⌃I` is a tab nobody types that way.
    private static func translate(
        _ shortcut: KeyboardShortcuts.Shortcut
    ) -> (character: String?, isDeadKey: Bool) {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return (nil, false) }

        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        func typed(_ carbonModifiers: Int) -> (text: String, isDead: Bool) {
            // Carbon modifier bits sit in the high byte; `UCKeyTranslate`
            // wants them in the low 8 as its own `modifierKeyState`.
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = data.withUnsafeBytes { buffer in
                UCKeyTranslate(
                    buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress!,
                    UInt16(shortcut.carbonKeyCode),
                    UInt16(kUCKeyActionDown),
                    UInt32(carbonModifiers >> 8) & 0xFF,
                    UInt32(LMGetKbdType()),
                    0,  // dead keys reported, not suppressed — they are the question
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
            }
            guard status == noErr else { return ("", false) }
            return (String(utf16CodeUnits: characters, count: length), length == 0 && deadKeyState != 0)
        }

        let chord = typed(shortcut.carbonModifiers)
        if chord.isDead { return (nil, true) }

        let printable = !chord.text.isEmpty
            && chord.text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        let unmodified = typed(0).text
        let shifted = typed(shiftKey).text
        let unique = chord.text != unmodified && chord.text != shifted

        return (printable && unique ? chord.text : nil, false)
    }

    /// Activate, *then* open — the order is load-bearing.
    ///
    /// Measured on macOS 26.6.2 with a `Settings`-scene `LSUIElement` app:
    /// calling the action without activating first leaves the window
    /// `isVisible == true` but `isKeyWindow == false`, with the app the user
    /// came from still frontmost. It opens behind them, which is
    /// indistinguishable from nothing happening. Activating first gives a key,
    /// frontmost window. Calling it again while it is already open is
    /// harmless, so there is no "already showing" branch to make.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        presentSettings?()
    }

    private func showOnboarding() {
        if let onboarding {
            NSApp.activate(ignoringOtherApps: true)
            onboarding.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(
            model: onboardingModel,
            models: modelSettings,
            requestAccessibility: { Self.openAccessibilitySettings() },
            shortcutText: { HotkeyManager.rendered($0) },
            collisionCaution: { Self.collisionCaution() },
            // Done marks it finished; the window's close button deliberately
            // does not, so an abandoned guide reopens where it stopped.
            finish: { [weak self] in
                self?.onboardingModel.markComplete()
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
