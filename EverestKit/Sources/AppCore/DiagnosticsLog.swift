import Foundation
import os

/// A small rotating text log a bug reporter can attach.
///
/// **Why a file at all, when the app already uses `OSLog`.** The unified log
/// is the better sink and stays the primary one, but everything interesting
/// this app records goes out at `.debug`, which macOS keeps in memory and
/// drops. By the time someone notices a problem worth reporting, the trail is
/// gone, and `log show` returns nothing. A file is what survives the gap
/// between the failure and the report.
///
/// **Never content.** Root `AGENTS.md` section 6, the same rule `Tracing`
/// follows: lengths, booleans, enum cases, versions and AX roles, never the
/// user's text. A diagnostics file is the single easiest way to leak the
/// thing this app promises not to keep, and it is going to be pasted into a
/// public issue tracker by definition.
public struct DiagnosticsLog: Sendable {
    public let directory: URL
    private let maxBytes: Int
    private let keep: Int

    /// Serialises writes. Several actors log, and interleaved appends from
    /// two threads produce a file with half-lines in it, which is worse than
    /// no file because it reads as corruption in the app rather than in the
    /// log.
    private let gate = OSAllocatedUnfairLock(initialState: ())

    /// 256 KB live plus one spare is about 4,000 lines: comfortably more than
    /// any single session produces, small enough to attach to an issue, and
    /// bounded whatever happens. The bound is `maxBytes * (keep + 1)`.
    public init(directory: URL, maxBytes: Int = 256_000, keep: Int = 1) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.keep = keep
    }

    /// `~/Library/Logs/Everest/`, which is where Console.app looks and where
    /// a Mac user is told to find application logs.
    public static func standard() -> DiagnosticsLog {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return DiagnosticsLog(
            directory: (base ?? URL(fileURLWithPath: NSHomeDirectory()))
                .appendingPathComponent("Logs/Everest", isDirectory: true)
        )
    }

    public var currentFile: URL { directory.appendingPathComponent("everest.log") }

    private func rotated(_ index: Int) -> URL {
        directory.appendingPathComponent("everest.\(index).log")
    }

    /// One line, timestamped, appended.
    ///
    /// Every failure here is swallowed on purpose. Diagnostics must never be
    /// the reason a rewrite fails, and a read-only Logs directory is a real
    /// state on a managed Mac.
    public func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("\(stamp)  \(line)\n".utf8)

        gate.withLock { _ in
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )

            // Rotate *before* writing, so a single line can never push the
            // live file past the cap. Checked on every append rather than on
            // a timer: the cap is the point of the type, and a check that
            // only runs at launch is not a cap.
            let size = (try? FileManager.default
                .attributesOfItem(atPath: currentFile.path)[.size]) as? Int ?? 0
            if size + entry.count > maxBytes {
                // Oldest out first, then shuffle down. The newest line always
                // survives; a log that discards what just happened is worse
                // than none, because the reported failure is the most recent
                // thing in it.
                if keep > 0 {
                    try? FileManager.default.removeItem(at: rotated(keep))
                    for index in stride(from: keep - 1, through: 1, by: -1) {
                        try? FileManager.default.moveItem(
                            at: rotated(index), to: rotated(index + 1)
                        )
                    }
                    try? FileManager.default.moveItem(at: currentFile, to: rotated(1))
                } else {
                    try? FileManager.default.removeItem(at: currentFile)
                }
            }

            if let handle = try? FileHandle(forWritingTo: currentFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                try? entry.write(to: currentFile, options: .atomic)
            }
        }
    }

    /// Written once per launch. These four facts answer the first round of
    /// questions on almost every report, so asking for them separately is a
    /// round trip that never needs to happen.
    public func writeHeader(version: String, build: String) {
        var machine = "unknown"
        var size = 0
        if sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 {
            var value = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 {
                machine = String(cString: value)
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        append("--- Everest \(version) (\(build))")
        append("--- macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(machine)")
    }
}
