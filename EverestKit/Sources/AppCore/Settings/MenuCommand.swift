/// The two global hotkeys Everest registers.
///
/// Named here rather than only in the app target so that "which commands have
/// a hotkey" is a fact `AppCore` holds and a test can pin. The app target's
/// translation into `KeyboardShortcuts.Name` is exhaustive over this enum, so
/// adding a case is a compile error there rather than a menu item that
/// silently never gets a label.
public enum Hotkey: CaseIterable, Sendable {
    case quickImprove
    case chooseStyle
}

/// What the status-item menu offers, and which of it is reachable by keyboard
/// from outside the app.
///
/// The menu shows the current binding beside a command that has one. It shows
/// it as trailing text and **never** as a `keyEquivalent`: the real bindings
/// are Carbon-registered global hotkeys the user can re-record, and a menu key
/// equivalent would be a second copy of that binding which goes stale the
/// moment they do — showing last week's chord beside today's binding. Read
/// fresh on every open, the text cannot drift.
public enum MenuCommand: CaseIterable, Sendable {
    case quickImprove
    case chooseStyle
    case settings
    case setupGuide
    case quit

    /// The global hotkey behind this command, if it has one.
    ///
    /// `nil` for the last three, and not because they are unbound: `⌘,` and
    /// `⌘Q` both work — but only while one of Everest's own windows is key.
    /// An accessory app owns no menu bar, so those key equivalents do nothing
    /// in the app the user is actually typing in, which is the only place this
    /// dropdown is ever open. Printing them beside these items would advertise
    /// a shortcut that does not work where it is being read.
    public var hotkey: Hotkey? {
        switch self {
        case .quickImprove: .quickImprove
        case .chooseStyle: .chooseStyle
        case .settings, .setupGuide, .quit: nil
        }
    }

    /// The fixed key equivalent macOS convention already gives this command.
    ///
    /// A different fact from `hotkey`, and the distinction is the point. A
    /// `hotkey` is user-recordable, so a menu key equivalent for one is a
    /// second copy that goes stale the moment they re-record — hence the
    /// badge, re-read on every open. `⌘,` cannot be re-recorded: it is a
    /// system convention, fixed, so a menu copy of it cannot drift and the
    /// stale-copy rule does not reach it. It is also honest *here*
    /// specifically, because while this menu is open Everest is handling
    /// events and the equivalent genuinely fires.
    ///
    /// The Command modifier is left implicit: `NSMenuItem` defaults
    /// `keyEquivalentModifierMask` to `.command`, so assigning "," is ⌘,.
    ///
    /// Quit and Setup Guide stay bare deliberately. `⌘Q` on a menu-bar app
    /// meant to keep running is an invitation nobody asked for, and Setup
    /// Guide has no convention to borrow.
    public var fixedKeyEquivalent: String? {
        switch self {
        case .settings: ","
        case .quickImprove, .chooseStyle, .setupGuide, .quit: nil
        }
    }
}
