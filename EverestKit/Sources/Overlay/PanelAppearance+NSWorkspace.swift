import AppKit

public extension PanelAppearance {
    /// Reads the three settings the user has already given the system.
    ///
    /// Read from `NSWorkspace` rather than the SwiftUI environment. The
    /// environment values are populated for views inside an application's
    /// normal window hierarchy; this content lives in an `NSHostingView` in a
    /// borderless panel that is never key and is not in a `WindowGroup`.
    /// `NSWorkspace` is where those environment values come from anyway, so
    /// reading the source removes a dependency that might not hold.
    ///
    /// Sampled once per `show()` rather than observed. The alternative is
    /// another observer whose lifetime has to be managed on the same paths
    /// that already manage the key monitors, and one thing that can leak is
    /// better than two. A user who flips a setting during a three-second
    /// rewrite sees it applied on the next one.
    static func current() -> PanelAppearance {
        let workspace = NSWorkspace.shared
        return PanelAppearance(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}
