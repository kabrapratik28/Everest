import Foundation

/// A unique directory under the system temp dir, removed when the test's
/// reference to it goes away.
///
/// Every test in this target roots its model storage here. Nothing in this
/// target may touch the real `~/Library/Application Support/Everest`: a test
/// that deletes a model would otherwise delete the developer's 2.3 GB download.
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("everest-engines-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `byteCount` bytes at `relativePath`, creating parent directories.
    @discardableResult
    func writeFile(_ relativePath: String, bytes byteCount: Int) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: byteCount).write(to: target)
        return target
    }
}
