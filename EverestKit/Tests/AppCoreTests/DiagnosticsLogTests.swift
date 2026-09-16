import Foundation
import Testing

@testable import AppCore

/// A file that grows forever is a bug report nobody can attach and a disk
/// nobody asked to fill. The cap is the whole reason this type exists rather
/// than an `append` call at each site, so it is what gets pinned.
///
/// Asserted as a **total** across every file the log owns, not per file.
/// Rotation that keeps one spare doubles the footprint, and a per-file check
/// would pass while the directory grew without limit.
@Suite("DiagnosticsLog")
struct DiagnosticsLogTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("everest-diag-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bytes(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.reduce(0) { total, name in
            let path = directory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
            return total + (size ?? 0)
        }
    }

    @Test("a log written far past its cap stays inside it, and keeps the newest lines")
    func theCapHoldsUnderSustainedWriting() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticsLog(directory: directory, maxBytes: 2_000, keep: 1)
        // Two hundred times the cap. A rotation that fired once, or a cap
        // checked only at launch, fails here and passes on a short run.
        for i in 1...4_000 {
            log.append("line \(i) with enough text on it to add up quickly")
        }

        let total = bytes(in: directory)
        #expect(total <= 2_000 * 2, "total across all files must stay inside cap * (keep + 1), was \(total)")
        #expect(total > 0, "positive control: something was actually written")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count <= 2, "one live file and one spare, never a pile, got \(files)")

        // Rotation must drop the oldest, not the newest: a log that discards
        // what just happened is worse than no log, because the failure being
        // reported is always the most recent thing in it.
        let live = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(live.contains("line 4000"), "the newest line has to survive")
        #expect(!live.contains("line 1"), "the oldest lines are what rotation is for")
    }

    /// The first thing a maintainer needs is which build, on what, and the
    /// reporter should not have to be asked separately for any of it.
    @Test("the header names the build and the machine")
    func headerCarriesWhatAReportNeeds() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticsLog(directory: directory, maxBytes: 100_000, keep: 1)
        log.writeHeader(version: "0.2.1", build: "6")

        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(text.contains("0.2.1"))
        #expect(text.contains("macOS"), "the OS version is the first question on every report")
        #expect(text.contains("arm64") || text.contains("x86_64"), "architecture decides whether MLX can run at all")
    }
}
