import CoreGraphics

public enum ProgressStyle: Equatable, Sendable {
    case hidden
    case indeterminate
    case determinate(Double)
}

/// The three accessibility settings the user has already told the system
/// about, and what each one changes about this panel.
///
/// Held as plain booleans rather than read at the point of use, so every
/// consequence below is a pure function that a test can pin down. Where the
/// booleans come from is a separate, untestable, three-line concern.
public struct PanelAppearance: Equatable, Sendable {
    public var reduceMotion: Bool
    public var reduceTransparency: Bool
    public var increaseContrast: Bool

    public init(reduceMotion: Bool, reduceTransparency: Bool, increaseContrast: Bool) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    public var animatesStateChange: Bool { !reduceMotion }

    public var usesTranslucentMaterial: Bool { !reduceTransparency }

    public var borderWidth: CGFloat { increaseContrast ? 2 : 0.5 }
    public var tintsStateSymbol: Bool { !increaseContrast }
    public var dimsSecondaryText: Bool { !increaseContrast }

    /// A determinate bar survives Reduce Motion because it carries position
    /// information; an indeterminate spinner is motion for its own sake and is
    /// exactly what the setting asks us to stop. The words in the header
    /// already say what is happening, so nothing is lost by dropping it.
    public func progressStyle(for state: PanelState) -> ProgressStyle {
        switch state {
        case let .preparing(progress):
            if let progress { return .determinate(progress) }
            return reduceMotion ? .hidden : .indeterminate
        case .capturing, .generating, .applying:
            return reduceMotion ? .hidden : .indeterminate
        case .success, .readOnly, .targetChanged, .refused, .error,
             .stylePicker, .heldForManualCopy:
            return .hidden
        }
    }
}
