import Foundation
import Synchronization

@testable import Engines

/// Errors a fake fetch can fail with, so a test can assert on the specific one.
enum FetchFailure: Error, Equatable {
    case connectionLost
}

/// A `ModelFetcher` that reports a scripted list of raw progress values, records
/// what it was asked for, and can stop partway.
///
/// The scripted values are deliberately hostile: out of order and out of range.
/// A real `HubClient` download reports `Progress.fractionCompleted` across many
/// files, which can both exceed 1 transiently and move backwards when the total
/// byte count is revised mid-download, so the smoothing is production behaviour
/// rather than test scaffolding.
final class ScriptedFetcher: ModelFetcher {
    let rawProgress: [Double]
    let failure: FetchFailure?

    private let requested = Mutex<(repo: String, revision: String)?>(nil)

    init(rawProgress: [Double], failure: FetchFailure? = nil) {
        self.rawProgress = rawProgress
        self.failure = failure
    }

    /// The revision the downloader asked for, or `nil` if it never asked.
    /// `nil` is the interesting value: it proves a rejected request never
    /// reached the network.
    var revisionRequested: String? {
        requested.withLock { $0?.revision }
    }

    /// The repository the downloader asked for, or `nil` if it never asked.
    var repoRequested: String? {
        requested.withLock { $0?.repo }
    }

    func fetch(
        repoID: String,
        revision: String,
        into destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        requested.withLock { $0 = (repo: repoID, revision: revision) }
        for value in rawProgress {
            progress(value)
        }
        if let failure {
            throw failure
        }
        return destination
    }
}

/// Collects progress values from a `@Sendable` callback for later assertion.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var recorded: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
