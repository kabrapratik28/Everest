import Foundation

/// Where a downloaded model lives on disk, and what it takes to remove it.
///
/// `root` is the Hugging Face cache root this app owns, normally
/// `~/Library/Application Support/Everest/Models/`. Tests pass a temp
/// directory. It is deliberately never `HubCache.default`
/// (`~/.cache/huggingface`), which is shared with every other tool on the
/// machine and which Settings could neither size nor safely delete.
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Layout

    /// `mlx-community/Qwen3-4B` → `models--mlx-community--Qwen3-4B`, matching
    /// `HubCache.repoDirectory`'s Python-compatible naming.
    static func cacheName(for repoID: String) -> String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    /// Every place one repository's bytes can be. Three of the four are **not**
    /// under `models--org--name/`:
    ///
    /// | Location | Written by |
    /// |---|---|
    /// | `models--org--name/` (`blobs/`, `refs/`, `snapshots/`) | `HubCache.repoDirectory` |
    /// | `.metadata/models--org--name/` | `HubCache.metadataDirectory`, a sibling |
    /// | `.locks/models--org--name/...` | `HubCache.lockPath(for:)` mirrors any cached path |
    /// | `.ready/models--org--name` | ours, see `isReady` |
    ///
    /// `delete` and `residualBytes` both walk exactly this list, which is what
    /// makes a nonzero residual after a delete a real signal. Add a fifth
    /// location to the cache layout and it must be added here, or the
    /// assertion quietly stops being one.
    func locations(for repoID: String) -> [URL] {
        let name = Self.cacheName(for: repoID)
        return [
            root.appendingPathComponent(name, isDirectory: true),
            root.appendingPathComponent(".metadata", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            root.appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            readyMarker(for: repoID),
        ]
    }

    func readyMarker(for repoID: String) -> URL {
        root.appendingPathComponent(".ready", isDirectory: true)
            .appendingPathComponent(Self.cacheName(for: repoID))
    }

    // MARK: - Readiness

    /// Records that `revision` of `repoID` was proven to load.
    ///
    /// Only a completed `loadContainer` may call this. A download can finish
    /// and still produce a model that will not load — a truncated safetensors
    /// file, or an architecture this build of mlx-swift-lm has no entry for —
    /// and a model in that state would otherwise report ready forever.
    public func markReady(_ repoID: String, revision: String) throws {
        let marker = readyMarker(for: repoID)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(revision.utf8).write(to: marker)
    }

    /// Whether `revision` of `repoID` has been proven to load.
    ///
    /// The marker stores the commit it was proven at rather than existing
    /// empty, so it survives relaunch and is invalidated by a revision change
    /// instead of vouching for weights it never saw.
    public func isReady(_ repoID: String, revision: String) -> Bool {
        guard let data = try? Data(contentsOf: readyMarker(for: repoID)) else { return false }
        return String(decoding: data, as: UTF8.self) == revision
    }

    /// Withdraws the readiness claim for `repoID`.
    public func clearReady(_ repoID: String) throws {
        let marker = readyMarker(for: repoID)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
    }

    /// The downloaded snapshot for `revision`, or `nil` if it is not on disk.
    ///
    /// Revisions are pinned commits, and `HubCache` stores a snapshot under
    /// its commit hash, so this is a direct lookup rather than a ref walk.
    public func installedSnapshot(for repoID: String, revision: String) -> URL? {
        let directory = root
            .appendingPathComponent(Self.cacheName(for: repoID), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? directory : nil
    }

    // MARK: - Removal

    /// Removes all four locations. Removing only the repository directory looks
    /// correct in testing, because the gigabytes do go away, and leaves the
    /// lock and metadata trees behind forever. They are small, which is exactly
    /// why the leak would sit there unnoticed.
    public func delete(_ repoID: String) throws {
        let manager = FileManager.default
        for location in locations(for: repoID) where manager.fileExists(atPath: location.path) {
            try manager.removeItem(at: location)
        }
    }

    /// Bytes still on disk for `repoID`, measured across the same four
    /// locations `delete` removes. A nonzero result after a delete means
    /// something was missed rather than merely moved.
    public func residualBytes(for repoID: String) -> Int64 {
        locations(for: repoID).reduce(0) { $0 + Self.byteCount(at: $1) }
    }

    // MARK: - Measuring

    /// Total logical bytes at `url`, zero if nothing is there.
    ///
    /// The plain-file branch is not a convenience. `FileManager.enumerator(at:)`
    /// returns `nil` for anything that is not a directory, so an
    /// enumerator-only implementation measures the `.ready` marker as zero and
    /// would report a clean delete that was not clean.
    public static func byteCount(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileSize(of: url) }

        guard
            let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += fileSize(of: child)
        }
        return total
    }

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}

public enum ModelStoreError: Error, Equatable, Sendable {
    /// A `.ready` marker outlived the weights it vouched for. Fatal rather
    /// than ignorable: reporting ready here means failing at generation time
    /// instead, on every hotkey press.
    case readyMarkerWithoutWeights(String)
}
