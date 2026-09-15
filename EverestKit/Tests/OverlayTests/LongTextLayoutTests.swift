import AppKit
import CoreGraphics
import Testing
@testable import Overlay

@Suite("Long text layout")
struct LongTextLayoutTests {
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    /// No spaces to break on. People rewrite text containing links constantly,
    /// so this is the most likely way the panel breaks in real use.
    static let unbrokenToken =
        "https://internal.example.com/dashboards/retention/cohort-analysis-2026-q3"
        + "?window=28d&segment=new_users&compare=previous_period&breakdown=acquisition_channel"

    /// Laid out with the same text engine SwiftUI uses underneath, at exactly
    /// the width the panel gives its body.
    static func measure(_ text: String, width: CGFloat) -> CGRect {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        ).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    @Test("a long unbroken token wraps inside the body width instead of overflowing it")
    func unbrokenTokenWrapsInsideTheBody() {
        let bodyWidth = PanelGeometry.bodyWidth(in: Self.screen)
        let oneLine = Self.measure("x", width: bodyWidth).height

        let wrapped = Self.measure(Self.unbrokenToken, width: bodyWidth)

        #expect(wrapped.width <= bodyWidth)
        #expect(wrapped.height > oneLine)
    }

    /// The body budget has to stay inside the window, or the text that wraps
    /// neatly at `bodyWidth` still runs under the panel's own edge.
    @Test("the body width fits inside the panel, and the panel never widens for its content")
    func panelNeverWidensForItsContent() {
        #expect(PanelGeometry.bodyWidth(in: Self.screen) > 0)
        #expect(PanelGeometry.bodyWidth(in: Self.screen) < PanelGeometry.width(in: Self.screen))

        for contentHeight in stride(from: 0.0, through: 4000.0, by: 400.0) {
            let layout = PanelGeometry.layout(contentHeight: contentHeight, in: Self.screen)
            #expect(layout.frame.width == PanelGeometry.preferredWidth, "\(contentHeight)")
        }
    }
}
