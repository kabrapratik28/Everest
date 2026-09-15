import AppKit
import CoreGraphics
import Testing
@testable import Overlay

/// The only test in this directory that opens a real window.
///
/// `NSPanelSurface` is below the seam and hand-checked for everything else,
/// but this fact cannot be checked from above it: every seam-level test
/// asserts the surface was *told* something, and a spy cannot see what the
/// window then does. Root `AGENTS.md` §0's "a green suite does not prove the
/// adapter" case, so the check sits on the real `NSPanel`.
@MainActor
@Suite("Panel key window")
struct PanelKeyWindowTests {
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    /// The panel never takes key status, in any state.
    ///
    /// It did, briefly, in terminal states — that was how ⌘C was consumed
    /// before the tap existed. But a key window receives *every* keystroke,
    /// and this one has no responder to answer them, so ⌘V died in an empty
    /// chain: the state whose own detail line reads "paste it where you want
    /// it" was the state preventing the paste. Measured against TextEdit —
    /// with `makeKey()`, ⌘V put nothing in the document; without it, the
    /// clipboard pasted.
    ///
    /// Consumption belongs to `CGEventTapKeyInterceptor`, which takes exactly
    /// the keys it acts on and leaves ⌘V alone. A key window cannot do that,
    /// which is why nothing here is ever key again.
    @Test("no state takes key status, so the app underneath keeps its own keystrokes")
    func noStateTakesKeyStatus() {
        let surface = NSPanelSurface()
        defer { surface.hide() }
        let layout = PanelGeometry.layout(contentHeight: 120, in: Self.screen)

        let states: [PanelState] = [
            .generating(text: "half a par"),
            .readOnly(text: "the rewrite"),
            .heldForManualCopy(text: "the rewrite", reason: "the window moved"),
            .error(reason: "the model ran out of memory"),
        ]

        for state in states {
            surface.present(
                state,
                layout: layout,
                followsTail: false,
                acceptsKey: state.acceptsKeyWindow
            )
            #expect(NSApplication.shared.keyWindow == nil, "\(state.kind)")
        }
    }
}
