import Foundation
import Testing

@testable import Engines

@Suite("ModelStore")
struct ModelStoreTests {
    /// `FileManager.enumerator(at:)` returns `nil` for anything that is not a
    /// directory. A size helper built only on the enumerator therefore measures
    /// a plain file as zero bytes.
    ///
    /// That matters here because one of the four things `delete` removes is the
    /// `.ready` marker, which IS a plain file. A zero-measuring helper would
    /// report a clean delete while the marker was still on disk, and the
    /// residual-bytes assertion that is supposed to catch a leak would be
    /// incapable of ever failing. A verification function that cannot fail is
    /// worse than none, because it is trusted.
    @Test("byte count measures a plain file, not only a directory")
    func byteCountMeasuresAPlainFile() throws {
        let temp = try TempDirectory()
        let marker = try temp.writeFile("ready-marker", bytes: 11)

        #expect(ModelStore.byteCount(at: marker) == 11)
    }

    /// `HubCache` scatters one repository across four locations, and three of
    /// them are NOT under `models--org--name/`: a sibling `.metadata/`, a
    /// top-level `.locks/` mirror of every cached path, and our own `.ready`
    /// marker. A previous implementation removed only the first and left the
    /// lock tree behind forever.
    ///
    /// The pre-delete assertion is what makes the post-delete one mean
    /// anything. Without it, a `residualBytes` that looked at one location, or
    /// that failed to recurse, would return 0 both before and after and the
    /// test would pass while the leak sat there.
    @Test("deleting a model leaves no residual bytes in any of the four cache locations")
    func deleteRemovesAllFourCacheLocations() throws {
        let temp = try TempDirectory()
        let store = ModelStore(root: temp.url)
        let repoID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        let dir = "models--mlx-community--Qwen3-4B-Instruct-2507-4bit"

        try temp.writeFile("\(dir)/blobs/abc123", bytes: 500)
        try temp.writeFile("\(dir)/refs/main", bytes: 40)
        try temp.writeFile("\(dir)/snapshots/deadbeef/config.json", bytes: 120)
        try temp.writeFile(".metadata/\(dir)/abc123.metadata", bytes: 60)
        try temp.writeFile(".locks/\(dir)/blobs/abc123.lock", bytes: 20)
        try temp.writeFile(".ready/\(dir)", bytes: 41)

        #expect(store.residualBytes(for: repoID) == 781)

        try store.delete(repoID)

        #expect(store.residualBytes(for: repoID) == 0)
    }
}
