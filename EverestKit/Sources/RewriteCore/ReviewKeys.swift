/// The keys the review pane answers to, chosen in Settings from short lists.
///
/// Lists, not a recorder: every choice here never types into the editor and
/// cannot collide with the other list or with the editor's own ⌘C, ⌘V and
/// ⌘Z, so there is nothing to validate and no way to pick a key that breaks
/// the pane. esc is on neither list, because it cancels in every state.
public struct ReviewKeys: Codable, Equatable, Sendable {
    public enum Replace: String, Codable, CaseIterable, Sendable {
        case returnKey, commandReturn, commandR

        /// As drawn on the pane's keycap.
        public var keycap: String {
            switch self {
            case .returnKey: "↩"
            case .commandReturn: "⌘↩"
            case .commandR: "⌘R"
            }
        }

        /// As listed in Settings: the name, then the keycap the pane draws.
        public var menuTitle: String {
            switch self {
            case .returnKey: "Return  ↩"
            case .commandReturn: "Command-Return  ⌘↩"
            case .commandR: "Command-R  ⌘R"
            }
        }
    }

    public enum Changes: String, Codable, CaseIterable, Sendable {
        case commandD, commandShiftE, tab

        public var keycap: String {
            switch self {
            case .commandD: "⌘D"
            case .commandShiftE: "⌘⇧E"
            case .tab: "tab"
            }
        }

        public var menuTitle: String {
            switch self {
            case .commandD: "Command-D  ⌘D"
            case .commandShiftE: "Command-Shift-E  ⌘⇧E"
            case .tab: "Tab"
            }
        }
    }

    public var replace: Replace
    public var changes: Changes

    public init(replace: Replace, changes: Changes) {
        self.replace = replace
        self.changes = changes
    }

    public static let standard = ReviewKeys(replace: .returnKey, changes: .commandD)
}
