/// Where the user last left the floating panel, as fractions of the visible
/// screen, so it lands in the same place on a display of any size.
///
/// `y` is the edge that stays put: the top edge when `pinsTop`, else the
/// bottom. A panel parked low grows upward and one parked high grows
/// downward, so neither runs off the edge it was parked against.
/// `Overlay.PanelGeometry` turns this into a frame and back; it lives here
/// only so `AppSettings` can store it.
public struct PanelAnchor: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var pinsTop: Bool

    public init(x: Double, y: Double, pinsTop: Bool) {
        self.x = x
        self.y = y
        self.pinsTop = pinsTop
    }
}
