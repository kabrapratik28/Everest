import CoreGraphics
import RewriteCore

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

    /// Centred, with the top edge a fifth of the way down: roughly where
    /// Spotlight opens, and clear of the chat composers at the bottom of a
    /// full-screen window, which the old bottom-centre panel sat on top of.
    public static let defaultAnchor = PanelAnchor(x: 0.5, y: 0.8, pinsTop: true)

    /// The anchor that reproduces a panel the user dropped at `frame`.
    ///
    /// The pinned edge is whichever is nearer the screen edge it faces, so
    /// the panel grows away from where it was parked rather than off it.
    public static func anchor(for frame: CGRect, in visibleFrame: CGRect) -> PanelAnchor {
        // The live `visibleFrame` reports `.zero` when no screen matches, and
        // a fraction of nothing is NaN, which would park the panel nowhere.
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return defaultAnchor }
        let pinsTop = frame.midY >= visibleFrame.midY
        return PanelAnchor(
            x: (frame.midX - visibleFrame.minX) / visibleFrame.width,
            y: ((pinsTop ? frame.maxY : frame.minY) - visibleFrame.minY) / visibleFrame.height,
            pinsTop: pinsTop
        )
    }

    public static func layout(
        contentHeight: CGFloat, in visibleFrame: CGRect, anchor: PanelAnchor = defaultAnchor
    ) -> PanelLayout {
        let width = width(in: visibleFrame)
        let height = min(max(contentHeight, 0), maxHeight(in: visibleFrame))
        let midX = visibleFrame.minX + visibleFrame.width * anchor.x
        let edgeY = visibleFrame.minY + visibleFrame.height * anchor.y

        // Proposed from the anchor, then held `margin` inside every edge.
        // `width` and `height` are already capped so both ranges are
        // non-empty, which is what keeps a remembered place from putting the
        // panel off a smaller screen than the one it was remembered on.
        let x = min(max(midX - width / 2, visibleFrame.minX + margin), visibleFrame.maxX - margin - width)
        let y = min(
            max(anchor.pinsTop ? edgeY - height : edgeY, visibleFrame.minY + margin),
            visibleFrame.maxY - margin - height
        )

        return PanelLayout(
            frame: CGRect(x: x, y: y, width: width, height: height),
            contentHeight: contentHeight
        )
    }
}
