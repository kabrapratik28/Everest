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

/// Settings carries `⌘,` as a real key equivalent; the recordable commands
/// carry none.
///
/// This is a different fact from `hotkey` and the distinction is the whole
/// point. A `hotkey` is user-recordable, so a menu key equivalent for one is
/// a second copy that goes stale the moment they re-record — which is why
/// those get a badge re-read on every open instead. `⌘,` cannot be
/// re-recorded: it is a fixed system convention, so a menu copy of it cannot
/// drift, and the rule in `Everest/App/AGENTS.md` does not reach it.
///
/// Quit and Setup Guide stay bare on purpose. `⌘Q` on a menu-bar app meant
/// to keep running is an invitation nobody asked for, and Setup Guide has no
/// convention to borrow.
@Test("Settings carries the fixed ⌘, convention; recordable commands carry none")
func onlySettingsHasAFixedKeyEquivalent() {
    #expect(MenuCommand.settings.fixedKeyEquivalent == ",")

    #expect(MenuCommand.quit.fixedKeyEquivalent == nil)
    #expect(MenuCommand.setupGuide.fixedKeyEquivalent == nil)

    // The two that are user-recordable must never carry one, whatever else
    // changes — that is the stale-copy rule.
    for command in MenuCommand.allCases where command.hotkey != nil {
        #expect(command.fixedKeyEquivalent == nil, "\(command) is recordable and must not be copied into a menu")
    }
}
