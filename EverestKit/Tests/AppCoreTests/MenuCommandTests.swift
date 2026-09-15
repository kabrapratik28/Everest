import Testing

@testable import AppCore

/// The status-item menu shows the binding beside the two commands that have
/// one, and nothing beside the three that do not.
///
/// `⌘,` and `⌘Q` exist, but only while one of Everest's own windows is key:
/// an accessory app owns no menu bar, so those key equivalents do nothing in
/// the app the user is actually typing in — which is the only place this
/// dropdown is ever open. Printing them here would advertise a shortcut that
/// does not work where it is read. The two rewrite commands are the opposite
/// case: they are Carbon-registered global hotkeys and work from anywhere,
/// which is exactly why they are worth showing.
///
/// This mapping is the single source of which commands are hotkey-backed. The
/// app target's translation into `KeyboardShortcuts.Name` is exhaustive over
/// `Hotkey`, so adding one here is a compile error there rather than a menu
/// item that silently never gets a label.
@Test("only the two global hotkeys are shown in the menu; the app-menu key equivalents are not")
func onlyGlobalHotkeysAreLabelled() {
    #expect(MenuCommand.quickImprove.hotkey == .quickImprove)
    #expect(MenuCommand.chooseStyle.hotkey == .chooseStyle)

    #expect(MenuCommand.settings.hotkey == nil)
    #expect(MenuCommand.setupGuide.hotkey == nil)
    #expect(MenuCommand.quit.hotkey == nil)

    // Every hotkey the app registers reaches a menu item, so a binding the
    // user records is always discoverable from the menu bar.
    #expect(Set(MenuCommand.allCases.compactMap(\.hotkey)) == Set(Hotkey.allCases))
}
