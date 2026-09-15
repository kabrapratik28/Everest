import CoreGraphics
import Testing
@testable import Overlay

@Suite("PanelGeometry")
struct PanelGeometryTests {
    /// A secondary display to the left of the built-in one: non-zero, negative
    /// origin. A frame computed from `width / 2` instead of `midX` passes on a
    /// screen at the origin and puts the panel off the side of this one.
    static let screen = CGRect(x: -1728, y: 300, width: 1728, height: 1079)

    @Test("panel is 460pt wide, horizontally centred, and sits near the bottom")
    func bottomCentred() {
        let frame = PanelGeometry.layout(contentHeight: 120, in: Self.screen).frame

        #expect(frame.width == 460)
        #expect(frame.midX == Self.screen.midX)
        #expect(frame.minY > Self.screen.minY)
        #expect(frame.maxY < Self.screen.midY)
    }

    @Test("height follows the content up to 40% of the visible screen and no further")
    func heightIsCappedAtFortyPercent() {
        let cap = Self.screen.height * 0.40

        #expect(PanelGeometry.layout(contentHeight: 180, in: Self.screen).frame.height == 180)
        #expect(PanelGeometry.layout(contentHeight: cap - 1, in: Self.screen).frame.height == cap - 1)
        #expect(PanelGeometry.layout(contentHeight: cap + 1, in: Self.screen).frame.height == cap)
        #expect(PanelGeometry.layout(contentHeight: 4000, in: Self.screen).frame.height == cap)
    }

    /// Capping the window is only half the job. If the layout also forgot how
    /// tall the content really was, the overflow would be clipped rather than
    /// scrollable and the end of an 8,000-character rewrite would be
    /// unreachable — along with the Copy button under it.
    @Test("past the cap the frame stops growing and the full content stays reachable")
    func overflowScrollsRatherThanBeingClipped() {
        let cap = Self.screen.height * 0.40

        let short = PanelGeometry.layout(contentHeight: 180, in: Self.screen)
        #expect(short.frame.height == 180)
        #expect(short.contentHeight == 180)
        #expect(short.scrolls == false)

        let tall = PanelGeometry.layout(contentHeight: 4000, in: Self.screen)
        #expect(tall.frame.height == cap)
        #expect(tall.contentHeight == 4000)
        #expect(tall.scrolls)
    }

    /// A short `visibleFrame` is ordinary — a scaled resolution, a large Dock,
    /// the menu bar and a Stage Manager strip all eat into it. 40% of a small
    /// number is a small number, and a fixed 96pt inset underneath it stops
    /// fitting. A panel hanging off the bottom of the screen looks broken.
    @Test("the panel fits entirely inside a small visible frame")
    func fitsInsideASmallScreen() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 150)
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 240)

        for screen in [short, narrow] {
            let layout = PanelGeometry.layout(contentHeight: 4000, in: screen)

            #expect(layout.frame.height > 0, "\(screen)")
            #expect(layout.frame.width > 0, "\(screen)")
            #expect(screen.contains(layout.frame), "\(screen) does not contain \(layout.frame)")
        }
    }

    /// Tail-following resumes when the user scrolls back to the bottom, so
    /// something has to decide what "the bottom" is. A strict equality never
    /// matches: scroll offsets are floats coming out of a scroll view that
    /// deals in fractional points, so following would switch off on the first
    /// gesture and never come back.
    @Test("at the bottom is a tolerance, not an equality")
    func atTheBottomIsATolerance() {
        // 1000pt of content in a 400pt window: the last scroll position is 600.
        #expect(PanelGeometry.isScrolledToBottom(offsetY: 600, visibleHeight: 400, contentHeight: 1000))
        #expect(PanelGeometry.isScrolledToBottom(offsetY: 599.7, visibleHeight: 400, contentHeight: 1000))
        #expect(PanelGeometry.isScrolledToBottom(offsetY: 400, visibleHeight: 400, contentHeight: 1000) == false)
        #expect(PanelGeometry.isScrolledToBottom(offsetY: 0, visibleHeight: 400, contentHeight: 1000) == false)

        // Content shorter than the window: there is nowhere to scroll, so the
        // user is always at the bottom. Saying otherwise would switch
        // following off for every short rewrite.
        #expect(PanelGeometry.isScrolledToBottom(offsetY: 0, visibleHeight: 400, contentHeight: 100))
    }

    /// `NSScreen.main` is the screen containing the key window, and this app
    /// deliberately never has one, so the panel follows the pointer instead.
    /// A display positioned left of or above the primary has a negative
    /// origin, which is where sign errors in this kind of lookup surface.
    @Test("the screen chosen is the one containing the pointer")
    func screenContainingThePointerIsChosen() {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let leftAndAbove = CGRect(x: -2560, y: 415, width: 2560, height: 1415)
        let screens = [primary, leftAndAbove]

        #expect(PanelGeometry.screen(containing: CGPoint(x: 800, y: 500), among: screens) == primary)
        #expect(PanelGeometry.screen(containing: CGPoint(x: -1200, y: 900), among: screens) == leftAndAbove)

        // The pointer can sit in the dead space between two misaligned
        // displays. Falling back beats returning nothing and beats a crash.
        #expect(PanelGeometry.screen(containing: CGPoint(x: 9_999, y: 9_999), among: screens) == primary)
        #expect(PanelGeometry.screen(containing: .zero, among: []) == nil)
    }
}
