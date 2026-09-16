import Foundation
import os

/// The one thing about a model download that cannot run in a unit test:
/// actually moving 2.3 GB over the network.
///
/// Everything around it — progress smoothing, readiness, failure handling —
/// lives in `ModelDownloader` and is driven against a fake conformer. The real
/// conformer is `HubModelFetcher`, which is integration-verified only.
public protocol ModelFetcher: Sendable {
    /// Downloads `repoID` at `revision` into `destination`, reporting raw
    /// progress. Values are *not* required to be ordered or in range; the
    /// caller smooths them.
    /// - Returns: the local directory containing the downloaded files.
    func fetch(
        repoID: String,
        revision: String,
        into destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

/// Fetches a model and keeps the on-disk readiness state honest.
public struct ModelDownloader: Sendable {
    let store: ModelStore
    let fetcher: any ModelFetcher

    public init(store: ModelStore, fetcher: any ModelFetcher) {
        self.store = store
        self.fetcher = fetcher
    }

    /// Downloads `repoID`, reporting a fraction that only moves forward within
    /// `0...1`.
    ///
    /// Completing the download does **not** mark the model ready. Only a
    /// proven load does, because a download can finish and still leave a
    /// truncated safetensors file that fails identically on every hotkey press.
    @discardableResult
    public func download(
        repoID: String,
        revision: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // A pinned commit, never a branch, and never a default.
        //
        // A moving `main` can swap the weights under an install already
        // proven to load, and the `.ready` marker still matches because the
        // revision string did not change. Defaulting this parameter would put
        // that failure one forgotten argument away, and it is silent when it
        // happens: everything works, and the guarantee is quietly gone.
        guard !revision.isEmpty else {
            throw ModelFetchError.missingPinnedRevision(repoID)
        }

        // Withdraw the readiness claim before touching the blobs it was made
        // about. If the fetch dies partway, what is on disk is a mix of two
        // revisions, and a surviving marker would make the app report ready
        // and then fail on every hotkey press with no way back.
        try store.clearReady(repoID)

        let reported = HighWaterMark()
        return try await fetcher.fetch(
            repoID: repoID,
            revision: revision,
            into: store.root
        ) { raw in
            progress(reported.advance(to: raw))
        }
    }
}

/// Clamps to `0...1` and never goes backwards.
///
/// `HubClient` reports `Progress.fractionCompleted` summed across many files,
/// which can exceed 1 transiently and can move backwards when the total byte
/// count is revised mid-download. A progress bar that does either reads as a
/// broken download rather than a broken readout.
private final class HighWaterMark: Sendable {
    private let value = OSAllocatedUnfairLock<Double>(initialState: 0)

    func advance(to raw: Double) -> Double {
        let clamped = min(max(raw, 0), 1)
        return value.withLock { current in
            current = max(current, clamped)
            return current
        }
    }
}
