import Foundation
import Testing

@testable import Engines

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    static let repoID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    static let pinned = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

    /// Progress reaches the UI as a fraction that only ever moves forward
    /// inside `0...1`. A progress bar that jumps backwards, or past its own
    /// end, reads as a bug in the download rather than in the reporting.
    ///
    /// The scripted input exercises all three corrections in one pass:
    /// `0.2` regresses after `0.25` and is held, `1.4` is out of range and is
    /// clamped, and `0.9` would regress after the clamp and is held again.
    @Test("download progress is monotonic and stays within 0 to 1")
    func progressIsMonotonicWithinZeroToOne() async throws {
        let temp = try TempDirectory()
        let downloader = ModelDownloader(
            store: ModelStore(root: temp.url),
            fetcher: ScriptedFetcher(rawProgress: [0.0, 0.25, 0.2, 1.4, 0.9])
        )
        let log = ProgressLog()

        _ = try await downloader.download(repoID: Self.repoID, revision: Self.pinned) { log.record($0) }

        #expect(log.recorded == [0.0, 0.25, 0.25, 1.0, 1.0])
    }

    /// A pinned revision is required, and it is what gets fetched.
    ///
    /// A moving `main` can swap the weights under an install that was already
    /// proven to load, and the `.ready` marker still matches because the
    /// revision *string* did not change. The user is then running weights
    /// nobody tested, with nothing to tell them so. This is the same argument
    /// that moved `mlx-swift-lm` off `branch: main`.
    ///
    /// Falling back to `"main"` on an empty revision is the failure worth a
    /// test, because it is silent: everything works, and the guarantee is
    /// gone. Asserting the fetcher was never asked (`nil`, not `"main"`) is
    /// what proves the rejection happened before the network, rather than
    /// after a download had already started.
    @Test("a pinned revision is required and is the one fetched")
    func pinnedRevisionIsRequiredAndIsTheOneFetched() async throws {
        let temp = try TempDirectory()
        let fetcher = ScriptedFetcher(rawProgress: [1.0])
        let downloader = ModelDownloader(store: ModelStore(root: temp.url), fetcher: fetcher)

        _ = try await downloader.download(repoID: Self.repoID, revision: Self.pinned) { _ in }
        #expect(fetcher.revisionRequested == Self.pinned)

        let rejecting = ScriptedFetcher(rawProgress: [1.0])
        let unpinned = ModelDownloader(store: ModelStore(root: temp.url), fetcher: rejecting)

        await #expect(throws: ModelFetchError.missingPinnedRevision(Self.repoID)) {
            try await unpinned.download(repoID: Self.repoID, revision: "") { _ in }
        }
        #expect(rejecting.revisionRequested == nil)
    }

    /// Readiness is a claim that this exact revision was proven to load. A
    /// re-download rewrites the blobs that claim was made about, so the moment
    /// a fetch starts the claim is stale, and if the fetch then dies partway
    /// the bytes on disk are a mix of two revisions.
    ///
    /// Leaving the marker in place there is the worst outcome available: the
    /// app reports `.ready`, fails identically on every hotkey press, and
    /// offers no path in the UI that would ever re-download. The test starts
    /// from a genuinely ready model so that failing to clear the marker is
    /// observable; asserting `isReady == false` on a model that was never
    /// ready would pass no matter what the downloader did.
    @Test("a download that fails partway leaves a previously ready model not ready")
    func failedDownloadDoesNotLeaveModelMarkedReady() async throws {
        let temp = try TempDirectory()
        let store = ModelStore(root: temp.url)
        try store.markReady(Self.repoID, revision: Self.pinned)
        #expect(store.isReady(Self.repoID, revision: Self.pinned))

        let downloader = ModelDownloader(
            store: store,
            fetcher: ScriptedFetcher(rawProgress: [0.0, 0.5], failure: .connectionLost)
        )

        await #expect(throws: FetchFailure.connectionLost) {
            try await downloader.download(repoID: Self.repoID, revision: Self.pinned) { _ in }
        }

        #expect(store.isReady(Self.repoID, revision: Self.pinned) == false)
    }
}
