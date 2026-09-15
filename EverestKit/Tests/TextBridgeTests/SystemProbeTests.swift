import AppKit
import Testing

@testable import TextBridge

/// `SystemProbe` is otherwise pure translation over three system calls and
/// is verified by running the app. The one place a decision lives is reading
/// the frontmost app's version, so that is what is driven here.
@Suite("System probe")
struct SystemProbeTests {

    /// A real bundle on disk, because the thing under test is what `Bundle`
    /// hands back for a missing or empty key, not what a stub hands back.
    private func makeBundle(version: String?) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "everest-probe-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(
            at: root.appending(path: "Contents"), withIntermediateDirectories: true)

        var info: [String: Any] = ["CFBundleIdentifier": "com.example.fixture"]
        if let version { info["CFBundleShortVersionString"] = version }

        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appending(path: "Contents/Info.plist"))
        return root
    }

    @Test("reads CFBundleShortVersionString from the running app's bundle")
    func readsTheShortVersionString() throws {
        let url = try makeBundle(version: "3.1.4")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SystemProbe.version(of: url) == "3.1.4")
    }

    /// The strategy cache keys on bundle id plus version, so the version has
    /// to mean something. An empty string is not a version, and handing one
    /// to the cache as though it were is a lie: `nil` is the honest
    /// representation of "this app did not tell us".
    @Test("a missing bundle, a missing key or an empty value all yield nil, never an empty string")
    func anAbsentVersionIsNilRatherThanEmpty() throws {
        let noKey = try makeBundle(version: nil)
        let empty = try makeBundle(version: "")
        defer {
            try? FileManager.default.removeItem(at: noKey)
            try? FileManager.default.removeItem(at: empty)
        }

        #expect(SystemProbe.version(of: nil) == nil, "an app with no bundle at all")
        #expect(
            SystemProbe.version(
                of: URL(fileURLWithPath: "/tmp/everest-absent-\(UUID().uuidString)")) == nil,
            "a path that is not a bundle"
        )
        #expect(SystemProbe.version(of: noKey) == nil, "a bundle with no version key")
        #expect(SystemProbe.version(of: empty) == nil, "a bundle with an empty version")
    }
}
