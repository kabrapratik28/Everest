//  ModelDownloader.swift
//  Everest
//
//  Downloads an MLX model repository from Hugging Face into Application Support
//  and tracks which downloads have been proven loadable. See AGENTS.md in this
//  directory for the decisions behind the on-disk layout and the ready marker.

import Foundation
import HuggingFace
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.download"
)

/// Failures that are worth showing to a person, phrased for a person.
public enum ModelDownloadError: LocalizedError, Equatable {
    case invalidRepositoryID(String)
    case noLocalCopy(String)
    case incompleteDownload(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "\"\(id)\" is not a Hugging Face repository id. Expected \"namespace/name\"."
        case .noLocalCopy(let id):
            return "No downloaded copy of \(id) was found on this Mac."
        case .incompleteDownload(let id):
            return "The download of \(id) finished but the files on disk are incomplete. Delete the model in Settings and download it again."
        case .cancelled:
            return "The download was cancelled."
        }
    }
}

/// Downloads and manages the local copies of MLX model repositories.
///
/// One instance owns the whole models directory, so concurrent callers asking for
/// the same repository share a single download instead of racing each other into
/// the same files.
public actor ModelDownloader {

    public static let shared = ModelDownloader()

    // MARK: - Locations

    /// `~/Library/Application Support/Everest/Models`.
    ///
    /// This doubles as the Hugging Face cache root, so a repository lands at
    /// `Models/models--<namespace>--<name>/snapshots/<commit>/`.
    public nonisolated static var modelsRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Everest/Models", directoryHint: .isDirectory)
    }

    private nonisolated static var readyMarkerRoot: URL {
        modelsRoot.appending(path: ".ready", directoryHint: .isDirectory)
    }

    // MARK: - Pinned revisions

    /// The exact commit each repository is pinned to.
    ///
    /// A moving branch can swap the weights under an install that was already
    /// proven to load. These hashes were read from the Hugging Face API on
    /// 2026-09-14. A repository with no entry here falls back to `main`.
    public nonisolated static let pinnedRevisions: [String: String] = [
        "mlx-community/Qwen3-4B-Instruct-2507-4bit":
            "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit":
            "e9675aa3ca5f900ccef55267914466d55ab325fa",
    ]

    public nonisolated static func revision(for repoID: String) -> String {
        pinnedRevisions[repoID] ?? "main"
    }

    /// The same glob set `MLXLMCommon.resolve(configuration:...)` uses.
    ///
    /// Kept in sync by hand because upstream declares it `package`-scoped. If the
    /// factory ever needs a file this set omits, the load fails with a missing-file
    /// error rather than anything subtle.
    private static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    // MARK: - State

    private let cache: HubCache
    private let client: HubClient
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init() {
        let root = Self.modelsRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.cache = HubCache(cacheDirectory: root)
        self.client = HubClient(cache: HubCache(cacheDirectory: root))
    }

    // MARK: - Inspection

    /// The local snapshot directory for a repository, if one exists on disk.
    public nonisolated func snapshotURL(for repoID: String) -> URL? {
        guard let repo = Repo.ID(rawValue: repoID) else { return nil }
        guard let commit = resolvedCommit(for: repo, repoID: repoID) else { return nil }
        guard let url = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether a downloaded copy exists *and* has been proven to load once.
    ///
    /// A repository that downloaded completely but failed to load is deliberately
    /// not ready: re-running the download is the only path that can fix it.
    public nonisolated func isReady(_ repoID: String) -> Bool {
        guard let repo = Repo.ID(rawValue: repoID) else { return false }
        guard let commit = resolvedCommit(for: repo, repoID: repoID) else { return false }
        guard snapshotURL(for: repoID) != nil else { return false }
        return markedCommit(for: repo) == commit
    }

    /// Bytes currently occupied by a repository, for the Settings model list.
    public nonisolated func installedBytes(for repoID: String) -> Int64 {
        guard let repo = Repo.ID(rawValue: repoID) else { return 0 }
        return directorySize(cache.repoDirectory(repo: repo, kind: .model))
    }

    // MARK: - Download

    /// Ensure a local copy of `repoID` exists, reporting a 0...1 fraction.
    ///
    /// The fraction only covers the download. Proving the model loads is the
    /// caller's job, and the caller calls ``markReady(_:)`` once it has.
    ///
    /// Concurrent calls for the same repository join the same download rather than
    /// starting a second one over the same files.
    @discardableResult
    public func download(
        repoID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let existing = inFlight[repoID] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [client] in
            guard let repo = Repo.ID(rawValue: repoID) else {
                throw ModelDownloadError.invalidRepositoryID(repoID)
            }
            let revision = Self.revision(for: repoID)
            log.info("model download starting")

            // Hugging Face weights progress by file size, so the fraction is
            // meaningful, but it is recomputed whenever the transfer restarts a
            // file. Clamp it to non-decreasing: a progress bar that walks
            // backwards reads as a failure even when the download is healthy.
            let monotonic = MonotonicFraction()

            let directory = try await client.downloadSnapshot(
                of: repo,
                kind: .model,
                revision: revision,
                matching: Self.downloadPatterns,
                progressHandler: { p in
                    progress(monotonic.next(p.fractionCompleted))
                }
            )

            try Task.checkCancellation()
            guard Self.looksComplete(directory) else {
                throw ModelDownloadError.incompleteDownload(repoID)
            }
            progress(1.0)
            log.info("model download finished")
            return directory
        }

        inFlight[repoID] = task
        defer { inFlight[repoID] = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw ModelDownloadError.cancelled
        }
    }

    /// Stop an in-flight download of `repoID`.
    ///
    /// Deliberately separate from `MLXEngine.cancel()`. Escaping out of a rewrite
    /// should not throw away a partly finished multi-gigabyte download, but the
    /// Settings button that started one has to be able to stop it. Partial files
    /// stay in the cache and the next attempt resumes from them.
    public func cancelDownload(repoID: String) {
        inFlight[repoID]?.cancel()
    }

    /// Whether a download of `repoID` is running right now.
    public func isDownloading(_ repoID: String) -> Bool {
        inFlight[repoID] != nil
    }

    /// Record that this exact commit loaded successfully.
    ///
    /// Called by the engine after the model factory returns, never before. The
    /// marker is what ``isReady(_:)`` reads on the next launch.
    public func markReady(_ repoID: String) {
        guard let repo = Repo.ID(rawValue: repoID),
            let commit = resolvedCommit(for: repo, repoID: repoID)
        else { return }
        let root = Self.readyMarkerRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(commit.utf8).write(to: root.appending(path: markerName(for: repo)), options: .atomic)
    }

    /// Remove every byte a repository put on disk.
    ///
    /// `HubCache` scatters a repository across four places, not one, and three of
    /// them sit outside the obvious `models--org--name` directory:
    ///
    /// - `models--org--name/` — `blobs/` (including any `<etag>.incomplete`),
    ///   `refs/`, `snapshots/`
    /// - `.metadata/models--org--name/` — sibling of the above, not inside it
    /// - `.locks/models--org--name/` — `HubCache.lockPath(for:)` mirrors any
    ///   cached path under a top-level `.locks` tree
    /// - `.ready/models--org--name` — ours
    ///
    /// Removing only the first leaves lock and metadata trees behind, so the disk
    /// figure in Settings never returns to zero and a user who deleted a model to
    /// reclaim space is quietly told it did not fully work. They are small, which
    /// is exactly why nobody would notice the leak until it had been there for a
    /// year.
    ///
    /// The in-progress `hf-download-*.tmp` files live in the system temp
    /// directory, not here, and belong to the OS to clean up.
    public func delete(_ repoID: String) throws {
        guard let repo = Repo.ID(rawValue: repoID) else {
            throw ModelDownloadError.invalidRepositoryID(repoID)
        }
        let fm = FileManager.default
        let directory = cache.repoDirectory(repo: repo, kind: .model)
        guard fm.fileExists(atPath: directory.path) else {
            throw ModelDownloadError.noLocalCopy(repoID)
        }
        try fm.removeItem(at: directory)
        try? fm.removeItem(at: cache.metadataDirectory(repo: repo, kind: .model))
        try? fm.removeItem(at: cache.lockPath(for: directory))
        try? fm.removeItem(at: Self.readyMarkerRoot.appending(path: markerName(for: repo)))
        log.info("model deleted")
    }

    /// Bytes a repository still occupies anywhere under the models root.
    ///
    /// Used to assert that ``delete(_:)`` actually finished. Counts the same four
    /// locations `delete` removes, so a nonzero result after a delete means
    /// something was missed rather than something was merely moved.
    public nonisolated func residualBytes(for repoID: String) -> Int64 {
        guard let repo = Repo.ID(rawValue: repoID) else { return 0 }
        let locations = [
            cache.repoDirectory(repo: repo, kind: .model),
            cache.metadataDirectory(repo: repo, kind: .model),
            cache.lockPath(for: cache.repoDirectory(repo: repo, kind: .model)),
            Self.readyMarkerRoot.appending(path: markerName(for: repo)),
        ]
        return locations.reduce(0) { $0 + directorySize($1) }
    }

    // MARK: - Paths

    private nonisolated func markerName(for repo: Repo.ID) -> String {
        "models--" + repo.description.replacingOccurrences(of: "/", with: "--")
    }

    private nonisolated func markedCommit(for repo: Repo.ID) -> String? {
        let url = Self.readyMarkerRoot.appending(path: markerName(for: repo))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commit a repository resolves to: the pin if it is a hash, otherwise
    /// whatever the local refs file says the branch pointed at when it downloaded.
    private nonisolated func resolvedCommit(for repo: Repo.ID, repoID: String) -> String? {
        let revision = Self.revision(for: repoID)
        if Self.isCommitHash(revision) { return revision }
        return cache.resolveRevision(repo: repo, kind: .model, ref: revision)
    }

    private nonisolated static func isCommitHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    /// A cheap structural check, not a substitute for loading the model.
    ///
    /// It only rules out the obvious half-download: no config, or no weights at
    /// all. A file that is present but truncated still gets through here and is
    /// caught by the load.
    private static func looksComplete(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appending(path: "config.json").path) else {
            return false
        }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasSuffix(".safetensors") }
    }

    /// Allocated bytes under `url`, counting `url` itself when it is a plain file.
    ///
    /// `FileManager.enumerator(at:)` returns nil for a non-directory, so without
    /// the single-file branch the `.ready` marker would always measure as zero and
    /// ``residualBytes(for:)`` would report a clean delete that was not.
    private nonisolated func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let own = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .isRegularFileKey,
        ])
        if own?.isRegularFile == true {
            return Int64(own?.totalFileAllocatedSize ?? 0)
        }

        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                options: [])
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .isRegularFileKey,
            ])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// A non-decreasing view of a fraction that can otherwise move backwards.
private final class MonotonicFraction: @unchecked Sendable {
    private let lock = NSLock()
    private var highWater: Double = 0

    func next(_ value: Double) -> Double {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        lock.lock()
        defer { lock.unlock() }
        highWater = max(highWater, clamped)
        return highWater
    }
}
