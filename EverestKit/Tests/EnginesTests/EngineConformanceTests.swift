import Foundation
import RewriteCore
import Testing

@testable import Engines

@Suite("RewriteEngine conformance")
struct EngineConformanceTests {
    /// The whole point of the protocol is that `RewriteCoordinator` holds one
    /// engine without knowing which. Nothing outside this directory is
    /// allowed to care whether a rewrite came from MLX or from Apple.
    ///
    /// This is a compile-time claim more than a runtime one: if either engine
    /// stops satisfying the protocol, this array stops building. The runtime
    /// assertion on `id` is there so the test is not vacuous if someone
    /// weakens the element type.
    @Test("both engines are usable through the RewriteEngine protocol")
    func bothEnginesConformToRewriteEngine() async throws {
        let temp = try TempDirectory()
        let engines: [any RewriteEngine] = [
            MLXEngine(
                id: .qwen4B,
                repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                approxBytes: 2_300_000_000,
                revision: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
                store: ModelStore(root: temp.url),
                fetcher: ScriptedFetcher(rawProgress: [1.0]),
                producer: ScriptedTokenProducer(deltas: [])
            ),
            AppleFoundationEngine(system: ScriptedAppleSystemModel()),
        ]

        #expect(engines.map(\.id) == [.qwen4B, .apple])
    }
}
