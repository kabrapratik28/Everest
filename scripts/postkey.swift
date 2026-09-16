// Post a key chord as a CGEvent at .cghidEventTap.
//
// `osascript ... keystroke` and cliclick's `t:` will NOT trigger Everest:
// Carbon's RegisterEventHotKey (what KeyboardShortcuts wraps) listens below
// the session tap, so only an HID-level event reaches it. Measured
// 2026-09-16: cliclick kd:alt t:r ku:alt left everest.log silent.
//
//   swiftc -O -o /tmp/postkey scripts/postkey.swift
//   /tmp/postkey opt r          # ⌥R
//   /tmp/postkey opt shift r    # ⌥⇧R
//   /tmp/postkey esc            # bare Escape
//   /tmp/postkey cmd a          # ⌘A

import CoreGraphics
import Foundation

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
    "m": 46, "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
]

let mods: [String: CGEventFlags] = [
    "cmd": .maskCommand, "opt": .maskAlternate, "alt": .maskAlternate,
    "shift": .maskShift, "ctrl": .maskControl,
]

var flags: CGEventFlags = []
var key: CGKeyCode?
for arg in CommandLine.arguments.dropFirst() {
    let a = arg.lowercased()
    if let m = mods[a] { flags.insert(m) } else if let c = codes[a] { key = c } else {
        FileHandle.standardError.write("unknown token \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
}
guard let key else {
    FileHandle.standardError.write("usage: postkey [cmd|opt|shift|ctrl]... <key>\n".data(using: .utf8)!)
    exit(2)
}

// A nil source is rejected by some taps; a private state source is accepted
// and does not inherit the caller's real modifier state.
let src = CGEventSource(stateID: .privateState)
for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else {
        FileHandle.standardError.write("could not create event\n".data(using: .utf8)!)
        exit(1)
    }
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(20_000)
}
