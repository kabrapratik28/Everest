import CoreGraphics

/// Where the panel goes, how big it is, and how much content is behind that.
///
/// `contentHeight` is the height the content actually wants, which is larger
/// than `frame.height` once the cap bites. Carrying both is what makes the
/// overflow scrollable rather than clipped: the window stops growing, the
/// document does not.
public struct PanelLayout: Equatable, Sendable {
    public let frame: CGRect
    public let contentHeight: CGFloat

    public var scrolls: Bool { contentHeight > frame.height }
}

/// Where the panel goes, as a pure function of the screen it goes on.
///
/// Deliberately not a method on the controller and takes a `CGRect` rather
/// than an `NSScreen`: placement is the part of a floating panel most likely
/// to be wrong, and a function of a few numbers can be tested without a window
/// server — including on screens nobody has plugged in.
public enum PanelGeometry {
    /// The width the panel wants. Fixed, because text measured at one width is
    /// the only text whose height is predictable, and a panel that changes
    /// width as it streams is noise.
    public static let preferredWidth: CGFloat = 460

    /// Distance from the bottom of the visible frame to the bottom of the
    /// panel, when there is room for it.
    public static let preferredBottomInset: CGFloat = 96

    /// Minimum gap to any edge of the visible frame.
    public static let margin: CGFloat = 12

    /// Inset from the panel edge to its content.
    public static let contentPadding: CGFloat = 16

    /// Past this fraction of the visible screen the panel has stopped being an
    /// overlay and has become a window. The content scrolls instead.
    public static let maxHeightFraction: CGFloat = 0.40

    /// How far from the end still counts as "the bottom". Scroll offsets are
    /// fractional, so an exact comparison never matches and tail-following
    /// would switch off on the first gesture and never resume.
    public static let bottomTolerance: CGFloat = 2

    public static func isScrolledToBottom(
        offsetY: CGFloat,
        visibleHeight: CGFloat,
        contentHeight: CGFloat
    ) -> Bool {
        // Content shorter than the window has nowhere to scroll, so the user
        // is always at the bottom of it.
        let lastOffset = max(0, contentHeight - visibleHeight)
        return offsetY >= lastOffset - bottomTolerance
    }

    /// The display the pointer is on, or the first one if it is nowhere —
    /// which happens in the dead space between two misaligned displays.
    public static func screen(containing point: CGPoint, among frames: [CGRect]) -> CGRect? {
        frames.first { $0.contains(point) } ?? frames.first
    }

    /// `preferredWidth`, unless the screen is too narrow to hold it.
    public static func width(in visibleFrame: CGRect) -> CGFloat {
        min(preferredWidth, max(0, visibleFrame.width - margin * 2))
    }

    /// The width the body text is laid out at. One number, and if it is wrong
    /// a URL runs under the panel's own edge instead of wrapping.
    public static func bodyWidth(in visibleFrame: CGRect) -> CGFloat {
        max(0, width(in: visibleFrame) - contentPadding * 2)
    }

    public static func maxHeight(in visibleFrame: CGRect) -> CGFloat {
        min(
            visibleFrame.height * maxHeightFraction,
            max(0, visibleFrame.height - margin * 2)
        )
    }

    public static func layout(contentHeight: CGFloat, in visibleFrame: CGRect) -> PanelLayout {
        let width = width(in: visibleFrame)
        let height = min(max(contentHeight, 0), maxHeight(in: visibleFrame))

        // Sit at the preferred inset, but never so high that the panel runs off
        // the top of a short screen. `max(margin, …)` keeps the second clamp
        // from pushing it below the bottom edge when the screen is tiny.
        let inset = min(preferredBottomInset, max(margin, visibleFrame.height - height - margin))

        return PanelLayout(
            frame: CGRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.minY + inset,
                width: width,
                height: height
            ),
            contentHeight: contentHeight
        )
    }
}
