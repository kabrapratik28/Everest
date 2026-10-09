import Foundation

/// The Ollama server at the address the user typed in Settings ▸ Model.
///
/// The field shows `http://localhost:11434/v1`, the address people copy from
/// other tools, but every request goes to Ollama's own API at the root:
/// `/api/chat` is the endpoint that can refuse an over-long prompt instead of
/// silently dropping its start (see `Ollama/AGENTS.md`). So one trailing
/// `/v1` is removed and any other path, a reverse proxy's prefix, is kept.
public struct OllamaServer: Sendable, Equatable {
    private let root: URLComponents
    private let host: String

    /// Nil unless the address is plain `http` or `https` with a host. A user,
    /// password, query or fragment would ride along on every request, and a
    /// path appended after a query lands in the wrong place.
    public init?(_ address: String) {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return nil }

        // The encoded path: `path` decodes, and writing it back would turn a
        // proxy's `ollama%2Ffoo` into two segments, a different route.
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path
        self.root = parts
        self.host = host
    }

    /// Loopback only. Anything else, this Mac's own `.local` name included,
    /// gets the "isn't on this Mac" warning: a false warning costs a glance,
    /// a missing one hides that text is leaving.
    public var isOnThisMac: Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "[::1]" || name == "::1" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil } && octets[0] == "127"
    }

    /// How messages name the server: host and port, as typed.
    public var displayHost: String {
        root.port.map { "\(host):\($0)" } ?? host
    }

    var chatURL: URL { endpoint("api/chat") }
    var tagsURL: URL { endpoint("api/tags") }
    var psURL: URL { endpoint("api/ps") }

    private func endpoint(_ name: String) -> URL {
        var parts = root
        parts.percentEncodedPath += "/" + name
        // A host and a scheme were checked in `init`, so this always forms.
        return parts.url!
    }
}
