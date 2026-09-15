/// One keystroke, reduced to the three things the panel cares about.
///
/// Deliberately not an `NSEvent`. The mapping from a key to an action is the
/// part worth testing, and an `NSEvent` cannot be constructed meaningfully in a
/// unit test. The adapter that builds one of these from a real `NSEvent` is
/// three lines and is the only untested part.
public struct Keystroke: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public static let escapeKeyCode: UInt16 = 53
    public static let returnKeyCode: UInt16 = 36
    public static let upArrowKeyCode: UInt16 = 126
    public static let downArrowKeyCode: UInt16 = 125

    public let keyCode: UInt16
    public let characters: String
    public let modifiers: Modifiers

    /// Shift counts as a modifier: only a bare digit picks a style, and ⇧3 is
    /// the user typing `#` into whatever app is in front.
    public var isPlain: Bool { modifiers.isEmpty }

    public init(keyCode: UInt16, characters: String, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }
}

public enum PanelKeyAction: Equatable, Sendable {
    case cancel
    case copy
    case pickStyle(index: Int)
    case commitHighlightedStyle
    case moveHighlight(by: Int)
}

public enum PanelKeyMap {
    /// How many picker rows get a number. A sixth style is still reachable with
    /// the arrows; giving it a digit nobody printed next to it is worse than
    /// giving it none.
    public static let numberedRows = 5

    public static func action(for keystroke: Keystroke, in state: PanelState) -> PanelKeyAction? {
        if keystroke.keyCode == Keystroke.escapeKeyCode { return .cancel }

        // Exactly ⌘, so ⌘⇧C and ⌘⌥C fall through to the app underneath.
        if keystroke.modifiers == .command,
           keystroke.characters.lowercased() == "c",
           state.copyableText != nil {
            return .copy
        }

        guard case let .stylePicker(presets) = state else { return nil }
        if keystroke.keyCode == Keystroke.returnKeyCode { return .commitHighlightedStyle }
        if keystroke.keyCode == Keystroke.upArrowKeyCode { return .moveHighlight(by: -1) }
        if keystroke.keyCode == Keystroke.downArrowKeyCode { return .moveHighlight(by: 1) }
        if keystroke.isPlain, let number = Int(keystroke.characters),
           (1 ... numberedRows).contains(number),
           number <= presets.count {
            return .pickStyle(index: number - 1)
        }
        return nil
    }
}
