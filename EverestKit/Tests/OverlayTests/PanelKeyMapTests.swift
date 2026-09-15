import Testing
import RewriteCore
@testable import Overlay

@Suite("PanelKeyMap")
struct PanelKeyMapTests {
    static let escape = Keystroke(keyCode: Keystroke.escapeKeyCode, characters: "\u{1B}", modifiers: [])
    static let enter = Keystroke(keyCode: Keystroke.returnKeyCode, characters: "\r", modifiers: [])
    static let arrowUp = Keystroke(keyCode: Keystroke.upArrowKeyCode, characters: "\u{F700}", modifiers: [])
    static let arrowDown = Keystroke(keyCode: Keystroke.downArrowKeyCode, characters: "\u{F701}", modifiers: [])

    /// Matched by character, not key code, so a keyCode of 0 is deliberate.
    static let commandC = Keystroke(keyCode: 0, characters: "c", modifiers: .command)

    /// Digits are matched by the character, not the key code, so a keyCode of 0
    /// here is deliberate: it would be wrong for the map to care.
    static func digit(_ value: Int, plain: Bool = true) -> Keystroke {
        Keystroke(keyCode: 0, characters: String(value), modifiers: plain ? [] : .command)
    }

    static let fiveStyles: [Preset] = (1 ... 5).map {
        Preset(name: "Style \($0)", subtitle: "sub \($0)", instruction: "do \($0)")
    }

    @Test("Escape cancels from every state")
    func escapeCancelsFromEveryState() {
        for state in PanelStateTests.samples {
            #expect(PanelKeyMap.action(for: Self.escape, in: state) == .cancel, "\(state.kind)")
        }
    }

    @Test("number keys 1 through 5 pick that style in the picker")
    func digitsOneThroughFivePickAStyle() {
        let picker = PanelState.stylePicker(presets: Self.fiveStyles)

        for number in 1 ... 5 {
            #expect(PanelKeyMap.action(for: Self.digit(number), in: picker) == .pickStyle(index: number - 1))
        }
    }

    @Test("Return commits the highlighted style in the picker")
    func returnCommitsTheHighlightedStyle() {
        let picker = PanelState.stylePicker(presets: Self.fiveStyles)

        #expect(PanelKeyMap.action(for: Self.enter, in: picker) == .commitHighlightedStyle)
    }

    /// The monitors stay armed for the whole transaction, not just while the
    /// picker is up, so this map sees every keystroke typed anywhere during a
    /// rewrite. Only Escape may mean something outside the picker.
    @Test("the picker's keys do nothing when the picker is not up")
    func pickerKeysDoNothingOutsideThePicker() {
        for state in PanelStateTests.samples where state.kind != .stylePicker {
            #expect(PanelKeyMap.action(for: Self.digit(2), in: state) == nil, "\(state.kind)")
            #expect(PanelKeyMap.action(for: Self.enter, in: state) == nil, "\(state.kind)")
        }
    }

    /// Only the first five rows get a digit. A sixth custom style is reachable
    /// with the arrows and gets no number rather than a wrong one.
    @Test("a number outside the numbered rows does nothing")
    func outOfRangeNumberDoesNothing() {
        let five = PanelState.stylePicker(presets: Self.fiveStyles)
        let three = PanelState.stylePicker(presets: Array(Self.fiveStyles.prefix(3)))
        let six = PanelState.stylePicker(
            presets: Self.fiveStyles + [Preset(name: "Custom", subtitle: "mine", instruction: "do")]
        )

        #expect(PanelKeyMap.action(for: Self.digit(0), in: five) == nil)
        #expect(PanelKeyMap.action(for: Self.digit(6), in: five) == nil)
        #expect(PanelKeyMap.action(for: Self.digit(9), in: five) == nil)
        #expect(PanelKeyMap.action(for: Self.digit(4), in: three) == nil)
        #expect(PanelKeyMap.action(for: Self.digit(6), in: six) == nil)
    }

    /// A global monitor cannot consume the event, so ⌘3 pressed in the app
    /// underneath reaches both that app and this map. Switching browser tabs
    /// while a picker happens to be open must not also pick a style.
    @Test("a digit with a modifier held is left to the app underneath")
    func modifiedDigitIsLeftAlone() {
        let picker = PanelState.stylePicker(presets: Self.fiveStyles)

        #expect(PanelKeyMap.action(for: Self.digit(3, plain: false), in: picker) == nil)
    }

    /// ⌘C rather than Return. Return is too dangerous for a convenience
    /// binding: if the become-key logic ever regressed, a leaked Return would
    /// send a Slack message or submit a form. A leaked ⌘C copies the frontmost
    /// app's own selection, which is harmless. It is also the universal copy
    /// idiom, so there is nothing to learn.
    @Test("Command-C copies in the states holding a rewrite, and nowhere else")
    func commandCCopiesOnlyWhereThereIsARewrite() {
        for state in PanelStateTests.samples {
            let expected: PanelKeyAction? = state.copyableText == nil ? nil : .copy
            #expect(PanelKeyMap.action(for: Self.commandC, in: state) == expected, "\(state.kind)")
        }
    }

    /// A bare `c` is the user typing into the app underneath.
    @Test("an unmodified C does not copy")
    func unmodifiedCDoesNotCopy() {
        let holding = PanelState.heldForManualCopy(text: "the rewrite", reason: "the window moved")
        let bareC = Keystroke(keyCode: 0, characters: "c", modifiers: [])

        #expect(PanelKeyMap.action(for: bareC, in: holding) == nil)
    }
}
