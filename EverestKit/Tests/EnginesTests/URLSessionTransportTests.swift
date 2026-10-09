import Foundation
import Network
import Testing
import os

@testable import Engines

/// A one-reply HTTP server on 127.0.0.1, so the production transport can be
/// tested against a real socket without leaving this Mac.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let received = OSAllocatedUnfairLock(initialState: [String]())

    var requests: [String] { received.withLock { $0 } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(reply: String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let received = received
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                received.withLock { $0.append(String(decoding: data ?? Data(), as: UTF8.self)) }
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield(()) }
        }
        listener.start(queue: .global())
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    deinit { listener.cancel() }
}

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
    static let done = #"{"model":"qwen3:14b","created_at":"2026-10-08T22:27:45.513288Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"# + "\n"

    /// A 307 or 308 keeps the POST body, which is the user's selection, and
    /// Settings would go on naming the server they chose while the text went
    /// to another. The redirect itself comes back as the answer instead.
    @Test("a redirect is never followed, so a selection cannot be re-sent to a server nobody chose", .timeLimit(.minutes(1)))
    func redirectsAreNotFollowed() async throws {
        let elsewhere = try await LoopbackServer(reply: "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(Self.done.utf8.count)\r\nConnection: close\r\n\r\n\(Self.done)")
        let chosen = try await LoopbackServer(reply: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(elsewhere.port)/api/chat\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(chosen.port)/api/chat")!)
        post.httpMethod = "POST"
        post.httpBody = Data("the user's selection".utf8)
        let (redirected, _) = try await URLSessionTransport().lines(for: post)
        #expect(redirected.statusCode == 307)
        #expect(elsewhere.requests.isEmpty)

        post.url = URL(string: "http://127.0.0.1:\(elsewhere.port)/api/chat")!
        let (direct, _) = try await URLSessionTransport().lines(for: post)
        #expect(direct.statusCode == 200)
        #expect(elsewhere.requests.count == 1)
    }
}
