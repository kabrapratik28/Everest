import Foundation

/// The one thing in the Ollama engine that touches the network. Everything
/// that decides anything sits on the tested side, in `OllamaClient`.
public protocol HTTPTransport: Sendable {
    /// The whole body, for small JSON answers.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The body line by line, for a streamed answer. Ending the returned
    /// stream must stop the request behind it.
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
}

/// `URLSession`, translated. No branches beyond the response cast.
///
/// An ephemeral session with every store switched off, never
/// `URLSession.shared`: its disk cache, cookies and stored credentials would
/// put Ollama's answers, which are rewrites of the user's text, on disk, and
/// `PRIVACY.md` says Everest never writes a selection or a rewrite there.
///
/// And no redirects. A 307 or 308 keeps the POST body, which is the user's
/// selection, so following one sends it to a server nobody chose while
/// Settings goes on naming the one they did. The redirect comes back as the
/// answer, and `OllamaClient` reports it as an error.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    private static let ephemeral: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }()

    public init() {
        session = Self.ephemeral
    }

    private final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let reading = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Escape, a newer rewrite, or a closed panel ends the stream; the
            // generation on the server has to stop with it, not run on into
            // a panel that is gone.
            continuation.onTermination = { _ in
                reading.cancel()
                bytes.task.cancel()
            }
        }
        return (http, stream)
    }
}
