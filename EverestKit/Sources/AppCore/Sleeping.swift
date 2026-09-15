import Foundation

/// The auto-dismiss wait, behind a seam.
///
/// Injected for one reason: a test of "the success panel closes after 1.2
/// seconds" that really waits 1.2 seconds is a slow test that proves less than
/// one which can read back *which* interval was asked for.
public protocol Sleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct TaskSleeper: Sleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
