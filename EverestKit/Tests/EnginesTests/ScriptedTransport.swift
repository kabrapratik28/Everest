import Foundation
import os

@testable import Engines

/// Stands in for an Ollama server: answers each path from a script and
/// records every request. The replies copy responses captured from a real
/// Ollama 0.13.0 on 2026-10-08, field for field, so a decoder that leans on a
/// field the real server sends is tested against it.
final class ScriptedTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = ""
        var lines: [String] = []
        var error: URLError?
        /// Hold the response until `release()`, like a server still loading the model.
        var holdsHeaders = false
        /// Hold after the line at this index until `release()`, like a
        /// generation mid-stream or a connection left open after the answer.
        var holdsAfterLine: Int?
        /// Answer with the selection the prompt carried, like a model that
        /// changes nothing, so a test need not predict where pieces fall.
        var echoes = false
    }

    private struct State {
        var replies: [String: [Reply]]
        var requests: [URLRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate = AsyncStream<Void>.makeStream()
    private let cancellations = AsyncStream<Void>.makeStream()

    /// `chat` is a queue, one reply per request; the last one repeats.
    init(tags: Reply = .tags([]), ps: Reply = .ps(nil), chat: [Reply] = []) {
        state = OSAllocatedUnfairLock(initialState: State(replies: ["/api/tags": [tags], "/api/ps": [ps], "/api/chat": chat]))
    }

    var requests: [URLRequest] { state.withLock(\.requests) }
    var chatRequests: [URLRequest] { requests.filter { $0.url?.path == "/api/chat" } }
    var chatBodies: [ChatBody] {
        chatRequests.compactMap { $0.httpBody }.compactMap { try? JSONDecoder().decode(ChatBody.self, from: $0) }
    }

    func release() { gate.continuation.finish() }

    /// Returns once a held producer has seen its task cancelled.
    func waitUntilProducerCancelled() async {
        var iterator = cancellations.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func reply(for request: URLRequest) -> Reply {
        state.withLock { state in
            state.requests.append(request)
            let path = request.url?.path ?? ""
            var queue = state.replies[path] ?? []
            defer { state.replies[path] = queue }
            if queue.count > 1 { return queue.removeFirst() }
            return queue.first ?? Reply(status: 404, body: "404 page not found", lines: ["404 page not found"])
        }
    }

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = reply(for: request)
        if let error = reply.error { throw error }
        try await holdIfAsked(reply)
        return (Data(reply.body.utf8), response(request, reply.status))
    }

    private func holdIfAsked(_ reply: Reply) async throws {
        guard reply.holdsHeaders else { return }
        for await _ in gate.stream {}
        if Task.isCancelled {
            cancellations.continuation.yield(())
            throw URLError(.cancelled)
        }
    }

    /// The text between the envelope tags `PromptBuilder` wraps a selection in.
    static func selection(in prompt: String) -> String {
        guard let open = prompt.range(of: "<selected_text_"),
            let lineEnd = prompt[open.upperBound...].firstIndex(of: "\n"),
            let close = prompt.range(of: "\n</selected_text_", options: .backwards)
        else { return "" }
        return String(prompt[prompt.index(after: lineEnd)..<close.lowerBound])
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        var reply = reply(for: request)
        if let error = reply.error { throw error }
        try await holdIfAsked(reply)
        if reply.echoes {
            let prompt = request.httpBody.flatMap { try? JSONDecoder().decode(ChatBody.self, from: $0) }?.messages.first?.content ?? ""
            reply.lines = Reply.chat([Self.selection(in: prompt)]).lines
        }
        let script = reply
        let gate = gate.stream
        let cancellations = cancellations.continuation
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let producer = Task {
                for (number, line) in script.lines.enumerated() {
                    continuation.yield(line)
                    if number == script.holdsAfterLine {
                        for await _ in gate {}
                        if Task.isCancelled {
                            cancellations.yield(())
                            continuation.finish(throwing: URLError(.cancelled))
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        return (response(request, script.status), stream)
    }
}

/// What a chat request carried, read back the way Ollama would read it.
struct ChatBody: Decodable, Equatable {
    struct Message: Decodable, Equatable {
        let role: String
        let content: String
    }
    struct Options: Decodable, Equatable {
        let temperature: Double
        let numPredict: Int
        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool
    let truncate: Bool
    let shift: Bool
    let options: Options
    /// Optional, so a body without it still decodes and says so.
    let keepAlive: String?
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, truncate, shift, options
        case keepAlive = "keep_alive"
    }
}

extension ScriptedTransport.Reply {
    private static func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    /// `/api/tags`, in the order given; names in `cloud` carry `remote_host`
    /// the way Ollama marks a model that runs on ollama.com.
    static func tags(_ names: [String], cloud: Set<String> = []) -> Self {
        let entries = names.map { name in
            cloud.contains(name)
                ? #"{"name":\#(quoted(name)),"model":\#(quoted(name)),"remote_model":\#(quoted(name)),"remote_host":"https://ollama.com:443","modified_at":"2026-10-01T09:00:00.000000000-07:00","size":384,"digest":"0000000000000000000000000000000000000000000000000000000000000000","details":{"parent_model":"","format":"","family":"","families":null,"parameter_size":"","quantization_level":""}}"#
                : #"{"name":\#(quoted(name)),"model":\#(quoted(name)),"modified_at":"2026-10-08T13:24:37.571087797-07:00","size":9276198565,"digest":"bdbd181c33f2ed1b31c972991882db3cf4d192569092138a7d29e973cd9debe8","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"14.8B","quantization_level":"Q4_K_M"}}"#
        }
        return Self(body: #"{"models":[\#(entries.joined(separator: ","))]}"#)
    }

    /// `/api/ps`: one running model with its context window, or none.
    static func ps(_ model: String?, context: Int = 4096) -> Self {
        guard let model else { return Self(body: #"{"models":[]}"#) }
        return Self(body: #"{"models":[{"name":\#(quoted(model)),"model":\#(quoted(model)),"size":9777740832,"digest":"bdbd181c33f2ed1b31c972991882db3cf4d192569092138a7d29e973cd9debe8","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"14.8B","quantization_level":"Q4_K_M"},"expires_at":"2026-10-08T14:37:44.25224-07:00","size_vram":9777740832,"context_length":\#(context)}]}"#)
    }

    /// A streamed `/api/chat` answer: one line per piece of content, then the
    /// final line with the stop reason. `doneReason: nil` drops the final
    /// line, like a connection that closed early.
    static func chat(_ content: [String], doneReason: String? = "stop") -> Self {
        let lines = content.map {
            #"{"model":"qwen3:14b","created_at":"2026-10-08T22:27:45.393559Z","message":{"role":"assistant","content":\#(quoted($0))},"done":false}"#
        }
        let final = doneReason.map {
            #"{"model":"qwen3:14b","created_at":"2026-10-08T22:27:45.513288Z","message":{"role":"assistant","content":""},"done":true,"done_reason":\#(quoted($0)),"total_duration":5993929458,"load_duration":5305947166,"prompt_eval_count":23,"prompt_eval_duration":553082167,"eval_count":4,"eval_duration":120766749}"#
        }
        return Self(lines: lines + (final.map { [$0] } ?? []))
    }

    static let echo = Self(echoes: true)

    /// An error answer as Ollama sends it: a status and `{"error": "..."}`.
    static func failure(_ status: Int, _ message: String) -> Self {
        let body = #"{"error":\#(quoted(message))}"#
        return Self(status: status, body: body, lines: [body])
    }
}
