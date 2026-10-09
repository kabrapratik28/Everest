import Foundation
import MLX
import Testing

@testable import Engines

/// Against MLX's own Metal allocator, off unless `EVEREST_MLX_LIVE=1`. Not in
/// the plain suite: MLX loads its metallib on first use, `swift build`
/// bundles none, and MLX's default error handler then exits the process.
/// `xcodebuild` bundles it. From `EverestKit/`:
///
///   TEST_RUNNER_EVEREST_MLX_LIVE=1 xcodebuild test -scheme EverestKit-Package \
///     -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
///     -only-testing:EnginesTests
@Suite("MLX memory, live", .enabled(if: ProcessInfo.processInfo.environment["EVEREST_MLX_LIVE"] == "1"))
struct MLXMemoryTests {
    /// MLX keeps freed GPU buffers for reuse, by default up to about 45 GB on
    /// a 48 GB Mac, and reuses one only for a request within two pages of its
    /// size. Measured 2026-10-08 (Qwen3 4B, five rewrites of new lengths):
    /// 6.8 GB, and 6.6 GB still held once the engine was released.
    @Test("loading a model caps MLX's buffer cache first, so freed memory goes back to macOS")
    func freedMemoryLeavesTheProcess() async throws {
        let empty = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // Nothing to load there, so this throws, but only after the cap is
        // set: it has to be in place before the first weight is allocated.
        await #expect(throws: (any Error).self) { try await MLXTokenProducer().load(from: empty) }

        let before = Memory.activeMemory
        var arrays = [32, 64, 128, 256].map { MLXArray.zeros([$0 * 262_144]) }  // MB of Float32
        eval(arrays)
        // Positive control: the memory really was allocated, so what follows
        // is about where it went.
        #expect(Memory.activeMemory - before >= 480 * 1_048_576)

        arrays.removeAll()
        // MLX trims its cache to the cap on the next allocation. Until then
        // the cap is soft: one freed buffer can overshoot it.
        eval(MLXArray.zeros([1]))
        #expect(Memory.activeMemory - before < 1_048_576)
        #expect(Memory.cacheMemory <= 20 * 1_048_576)
    }
}
