import AppKit

public extension Keystroke {
    /// Reduces a real key event to the three things `PanelKeyMap` looks at.
    ///
    /// `charactersIgnoringModifiers` rather than `characters`, so the digit row
    /// works on layouts where a modifier would change the glyph. Shift counts
    /// as a modifier here even though it does not change the meaning of most
    /// keys: only a bare digit picks a style, and ⇧3 is the user typing `#`
    /// into whatever app is in front.
    init(_ event: NSEvent) {
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if held.contains(.command) { modifiers.insert(.command) }
        if held.contains(.option) { modifiers.insert(.option) }
        if held.contains(.control) { modifiers.insert(.control) }
        if held.contains(.shift) { modifiers.insert(.shift) }

        self.init(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: modifiers
        )
    }
}
