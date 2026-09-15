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
/// moment they do — showing `⌃⌥I` in the menu while the hotkey is `⌥R`. Read
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
}
