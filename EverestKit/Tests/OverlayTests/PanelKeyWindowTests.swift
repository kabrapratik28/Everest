import AppKit
import CoreGraphics
import Testing
@testable import Overlay

/// The only test in this directory that opens a real window.
///
/// `NSPanelSurface` is below the seam and is hand-checked for everything else,
/// but this one fact cannot be checked from above it. Every seam-level test
/// asserts the surface was *told* `acceptsKey`, and it was told correctly all
/// along — `keyStatusFollowsTheState` passed throughout the bug. What was
/// missing was the surface acting on what it was told, and a spy cannot see
/// that. This is the "a green suite does not prove the adapter" case in root
/// `AGENTS.md` §0, so the check has to sit on the real `NSPanel`.
@MainActor
@Suite("Panel key window")
struct PanelKeyWindowTests {
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    /// `canBecomeKey` is permission, not action. Returning true from it asks
    /// nobody for anything: until something calls `makeKey`, the panel stays
    /// non-key, our local monitor never runs, and the frontmost app processes
    /// the same ⌘C — its Copy landing *after* ours and overwriting the rewrite
    /// on the clipboard. In `heldForManualCopy` the panel is the user's only
    /// copy, so the keystroke the panel advertises is the one that loses it.
    @Test("a terminal state takes key status; a state that still intends a write does not")
    func terminalStatesTakeKeyStatus() {
        let surface = NSPanelSurface()
        defer { surface.hide() }
        let layout = PanelGeometry.layout(contentHeight: 120, in: Self.screen)

        surface.present(
            .generating(text: "half a par"),
            layout: layout, followsTail: true, acceptsKey: false
        )
        #expect(NSApplication.shared.keyWindow == nil)

        surface.present(
            .heldForManualCopy(text: "the rewrite", reason: "the window moved"),
            layout: layout, followsTail: false, acceptsKey: true
        )
        #expect(NSApplication.shared.keyWindow != nil)
    }
}
