import Testing

@testable import Overlay

/// The picker is the first and usually only place someone sees the style
/// list, so it is where they should learn the list is theirs to change.
///
/// `AppSettings.styles` is user-editable and uncapped — `PanelKeyMap`
/// numbers nine rows precisely because people add their own — and nothing on
/// this screen said so. Someone who dislikes all six shipped styles had no
/// reason to believe a seventh was possible.
@Test("the style picker points at Settings, and names no shortcut doing it")
func theStylePickerHintPointsAtSettings() {
    let hint = StylePickerView.settingsHint

    #expect(hint.localizedCaseInsensitiveContains("Settings"))

    // **No glyph, ever.** `ShortcutCopy` exists because prose naming a
    // binding went stale three times and broke a first run; a hint that
    // hardcoded ⌥⇧R would be the fourth.
    #expect(hint.contains("⌥") == false)
    #expect(hint.contains("⌘") == false)
    #expect(hint.contains("⌃") == false)
}
