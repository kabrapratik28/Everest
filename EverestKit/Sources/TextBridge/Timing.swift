import Foundation

extension Duration {
    /// `Duration` is the right type for a budget, `TimeInterval` is what the
    /// blocking primitives take. One conversion in one place.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
