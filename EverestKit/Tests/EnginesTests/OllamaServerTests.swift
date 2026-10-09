import Foundation
import Testing

@testable import Engines

/// The address the user types in Settings, and where Everest sends requests.
@Suite("OllamaServer")
struct OllamaServerTests {
    /// The field shows `http://localhost:11434/v1`, the address people copy
    /// from other tools, but rewrites go to Ollama's own API at the root.
    @Test("an address with or without /v1 reaches the server's own API, keeping any path prefix")
    func addressesReachTheNativeAPI() throws {
        for address in ["http://localhost:11434/v1", "http://localhost:11434/v1/", "http://localhost:11434", " http://localhost:11434/V1 "] {
            let server = try #require(OllamaServer(address), "\(address)")
            #expect(server.chatURL.absoluteString == "http://localhost:11434/api/chat")
            #expect(server.tagsURL.absoluteString == "http://localhost:11434/api/tags")
            #expect(server.psURL.absoluteString == "http://localhost:11434/api/ps")
        }
        #expect(OllamaServer("https://box.example.com/ollama/v1")?.chatURL.absoluteString == "https://box.example.com/ollama/api/chat")
        // An encoded separator is part of the proxy's route, not a new segment.
        #expect(OllamaServer("http://box.example.com/ollama%2Ffoo/v1")?.chatURL.absoluteString == "http://box.example.com/ollama%2Ffoo/api/chat")
    }

    /// Anything else gets the "isn't on this Mac" warning, including this
    /// Mac's own `.local` name: a false warning costs a glance, a missing one
    /// hides that text is leaving.
    @Test("only loopback addresses count as this Mac")
    func onlyLoopbackIsThisMac() {
        for local in ["http://localhost:11434/v1", "http://LOCALHOST:11434", "http://127.0.0.1:11434", "http://127.1.2.3:11434", "http://[::1]:11434/v1"] {
            #expect(OllamaServer(local)?.isOnThisMac == true, "\(local)")
        }
        for remote in ["http://192.168.1.20:11434/v1", "http://my-mac.local:11434", "http://127.example.com:11434", "https://example.com/v1"] {
            #expect(OllamaServer(remote)?.isOnThisMac == false, "\(remote)")
        }
    }

    /// Credentials, a query or a fragment would be carried into every
    /// request, and appending a path to them puts it in the wrong place.
    @Test("anything but a plain http or https address is refused")
    func malformedAddressesAreRefused() {
        #expect(OllamaServer("http://localhost:11434/v1") != nil)
        for bad in ["", "localhost:11434", "ftp://localhost/v1", "http://", "http://localhost:11434/v1?x=1", "http://localhost:11434/v1#top", "http://user:pass@localhost:11434/v1"] {
            #expect(OllamaServer(bad) == nil, "\(bad)")
        }
    }

    @Test("messages name the host and port the user typed")
    func displayHostIsWhatTheUserTyped() {
        #expect(OllamaServer("http://localhost:11434/v1")?.displayHost == "localhost:11434")
        #expect(OllamaServer("http://[::1]:11434")?.displayHost == "[::1]:11434")
        #expect(OllamaServer("https://box.example.com/v1")?.displayHost == "box.example.com")
    }
}
