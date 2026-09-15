import Foundation
import HuggingFace
import os

/// The real `ModelFetcher`: translation onto `HubClient`, and nothing else.
///
/// **Integration-only.** Nothing in this type is unit-tested, because the
/// behaviour it has is "2.3 GB arrives over the network". That is exactly why
/// it holds no decisions: progress smoothing, readiness and failure handling
/// all live in `ModelDownloader`, which is driven against a fake. If you find
/// yourself adding an `if` here, it belongs on the other side of the seam.
public struct HubModelFetcher: ModelFetcher {
    /// The same globs `MLXLMCommon.ModelFactory` uses. Downloading everything
    /// would also pull READMEs and, on a multi-modal repo, a vision encoder.
    static let fileGlobs = ["*.safetensors", "*.json", "*.jinja"]

    public init() {}

    public func fetch(
        repoID: String,
        revision: String,
        into destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: repoID) else {
            throw ModelFetchError.malformedRepositoryID(repoID)
        }

        // Rooting the cache at our own directory is what keeps one copy on
        // disk. `HubCache.default` is `~/.cache/huggingface`, shared with
        // every other tool on the machine, which Settings could neither size
        // nor safely delete. The `to: destination` overload of
        // `downloadSnapshot` is also deliberately not used: it copies every
        // file out of the cache with `FileManager.copyItem`, which would mean
        // 4.6 GB on disk for a 2.3 GB model and 34 GB for the 30B option.
        let client = HubClient(cache: HubCache(cacheDirectory: destination))

        return try await client.downloadSnapshot(
            of: repo,
            revision: revision,
            matching: Self.fileGlobs,
            progressHandler: { update in progress(update.fractionCompleted) }
        )
    }
}

public enum ModelFetchError: Error, Equatable, Sendable {
    /// A repository identifier that is not `namespace/name`.
    case malformedRepositoryID(String)
    /// No pinned commit for this repository. Deliberately fatal rather than
    /// falling back to a branch: see `ModelDownloader.download`.
    case missingPinnedRevision(String)
}
