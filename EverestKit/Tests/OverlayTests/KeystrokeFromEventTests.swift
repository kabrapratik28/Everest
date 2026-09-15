import AppKit
import Testing
@testable import Overlay

@Suite("Keystroke from NSEvent")
struct KeystrokeFromEventTests {
    static func event(
        characters: String,
        ignoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// Only a bare digit picks a style. ⌘3 switches a browser tab in the app
    /// underneath and ⇧3 types `#`; a global monitor sees both and must leave
    /// both alone.
    @Test("only an unmodified key counts as plain")
    func onlyAnUnmodifiedKeyIsPlain() {
        let bare = Self.event(characters: "3", ignoringModifiers: "3", modifiers: [], keyCode: 20)
        #expect(Keystroke(bare).isPlain)
        #expect(Keystroke(bare).characters == "3")
        #expect(Keystroke(bare).keyCode == 20)

        for held: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            let modified = Self.event(characters: "#", ignoringModifiers: "3", modifiers: held, keyCode: 20)
            #expect(Keystroke(modified).isPlain == false)
        }
    }

    /// Read the key the user pressed, not the glyph their layout produced.
    @Test("the character is taken ignoring modifiers")
    func charactersIgnoreModifiers() {
        let shifted = Self.event(characters: "#", ignoringModifiers: "3", modifiers: .shift, keyCode: 20)

        #expect(Keystroke(shifted).characters == "3")
    }
}
