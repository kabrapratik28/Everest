import Foundation
import RewriteCore

/// What the Model tab shows for an Ollama server: its local models, and
/// whether a rewrite could use one. One answer for both, from one request,
/// so the dropdown and the row can never disagree.
public struct OllamaStatus: Sendable, Equatable {
    public let models: [String]
    public let availability: EngineAvailability

    public init(models: [String], availability: EngineAvailability) {
        self.models = models
        self.availability = availability
    }
}

/// Everything that can go wrong with the user's Ollama, in words that say
/// what to do. The host in a message is always the one the user typed.
public enum OllamaError: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable(host: String)
    /// macOS refused plain http to a host outside this Mac and the local network.
    case needsHTTPS(host: String)
    case noModelChosen
    /// Not a local model on that server: removed, or one that runs on ollama.com.
    case modelUnavailable(name: String, host: String)
    /// Everest's own prompt leaves no room for any text in this window.
    case contextTooSmall(window: Int)
    /// Ollama refused a piece as longer than its window (`truncate: false`).
    case inputTooLong
    /// One word or link is longer than a piece, and a word is never cut.
    case wordTooLong
    case badResponse(status: Int)
    /// The answer ended without Ollama saying it was finished.
    case interrupted

    /// For the floating panel, after a hotkey press.
    public var message: String {
        switch self {
        case .invalidAddress:
            "The Ollama address in Settings ▸ Model isn't a web address. It should look like http://localhost:11434/v1."
        case let .unreachable(host):
            "Everest can't reach Ollama at \(host). Open Ollama, or pick another model in Settings ▸ Model."
        case let .needsHTTPS(host):
            "macOS only allows plain http to this Mac and your local network, so Everest can't reach Ollama at \(host). Use an https address, or pick another model in Settings ▸ Model."
        case .noModelChosen:
            "Choose an Ollama model in Settings ▸ Model."
        case let .modelUnavailable(name, host):
            "\(name) isn't one of the local models Ollama has at \(host). Pick another model in Settings ▸ Model."
        case let .contextTooSmall(window):
            "This Ollama model's context window (\(window) tokens) is too small for Everest's prompt. Raise the context length in Ollama's settings, or pick another model."
        case .inputTooLong:
            "This passage didn't fit in the Ollama model's context window, even in pieces. Nothing was changed. Select less, or raise the context length in Ollama's settings."
        case .wordTooLong:
            "Part of this selection, a single word or link, is too long for the Ollama model's context window. Nothing was changed. Select less, or raise the context length in Ollama's settings."
        case .badResponse:
            "Ollama answered with an error. Nothing was changed. Try again, or pick another model in Settings ▸ Model."
        case .interrupted:
            "Ollama stopped partway through. Nothing was changed. Try again."
        }
    }

    /// For the Ollama row in Settings ▸ Model, where "pick another model in
    /// Settings" would point at the screen the user is already on.
    public var rowStatus: String {
        switch self {
        case .invalidAddress:
            "That isn't a web address. It should look like http://localhost:11434/v1."
        case let .unreachable(host):
            "Can't reach Ollama at \(host). Open Ollama, then press ↻."
        case let .needsHTTPS(host):
            "macOS only allows plain http to this Mac and your local network. Use an https address for \(host)."
        case .badResponse:
            "Ollama answered with an error. Check the address, then press ↻."
        default:
            message
        }
    }
}

/// The body of a `POST /api/chat`.
///
/// `truncate: false` and `shift: false` are the reason this is Ollama's own
/// endpoint and not `/v1/chat/completions`, which can set neither. Without the
/// first, an over-long prompt keeps its first few tokens and loses the ones
/// after them, where the safety frame sits; without the second, a full window
/// slides and the model keeps writing without the start of its instructions.
/// `think: false` never errors on a model that cannot think (Ollama 0.13.0,
/// `server/routes.go`) and cut one sentence from 7.5 s to 0.8 s on `qwen3:14b`.
struct ChatRequest: Encodable, Equatable {
    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }
    struct Options: Encodable, Equatable {
        let temperature: Float
        let numPredict: Int
        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }

    let model: String
    let messages: [Message]
    let stream = true
    let think = false
    let truncate = false
    let shift = false
    let options: Options

    init(model: String, prompt: String, numPredict: Int) {
        self.model = model
        messages = [Message(role: "user", content: prompt)]
        options = Options(temperature: EngineLimits.temperature, numPredict: numPredict)
    }
}

enum ChatEvent: Equatable {
    case text(String)
    case done(reason: String?)
}

/// Talks to the user's Ollama through `HTTPTransport`. Every decision about
/// what an answer means lives here, where a test can reach it.
public struct OllamaClient: Sendable {
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    static let noModels = "Ollama has no models on this server yet. Add one with ollama pull, then press ↻."

    public func status(at address: String) async -> OllamaStatus {
        guard let server = OllamaServer(address) else {
            return OllamaStatus(models: [], availability: .unavailable(reason: OllamaError.invalidAddress.rowStatus))
        }
        do {
            let models = try await localModels(at: server)
            return OllamaStatus(models: models, availability: models.isEmpty ? .unavailable(reason: Self.noModels) : .ready)
        } catch let error as OllamaError {
            return OllamaStatus(models: [], availability: .unavailable(reason: error.rowStatus))
        } catch {
            return OllamaStatus(models: [], availability: .unavailable(reason: OllamaError.unreachable(host: server.displayHost).rowStatus))
        }
    }

    /// The models that run on that server itself, in its own order. An entry
    /// with `remote_host` runs on ollama.com, and picking it would send the
    /// selection there, so it is left out.
    func localModels(at server: OllamaServer) async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable {
                let name: String
                let remoteHost: String?
            }
            let models: [Model]
        }
        let (data, response) = try await get(server.tagsURL, at: server)
        guard response.statusCode == 200 else { throw OllamaError.badResponse(status: response.statusCode) }
        guard let tags = try? Self.decoder.decode(Tags.self, from: data) else { throw OllamaError.badResponse(status: 200) }
        return tags.models.filter { $0.remoteHost == nil }.map(\.name)
    }

    /// The window the model is loaded with, from `/api/ps`, or nil when it is
    /// not loaded or the answer is unusable. Only cancellation is thrown: an
    /// unknown window falls back to a default, a cancelled rewrite must stop.
    func contextWindow(for model: String, at server: OllamaServer) async throws -> Int? {
        struct Running: Decodable {
            struct Model: Decodable {
                let name: String
                let model: String?
                let contextLength: Int?
            }
            let models: [Model]
        }
        do {
            let (data, response) = try await get(server.psURL, at: server)
            guard response.statusCode == 200 else { return nil }
            let running = try Self.decoder.decode(Running.self, from: data)
            let length = running.models.first { $0.name == model || $0.model == model }?.contextLength
            return length.flatMap { $0 > 0 ? $0 : nil }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// A streamed `/api/chat`. Ending the returned stream cancels the request.
    func chat(_ request: ChatRequest, at server: OllamaServer) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var post = URLRequest(url: server.chatURL, timeoutInterval: 300)
                    post.httpMethod = "POST"
                    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    post.httpBody = try JSONEncoder().encode(request)

                    let (response, lines) = try await transport.lines(for: post)
                    guard response.statusCode == 200 else {
                        var body = ""
                        for try await line in lines { body += line }
                        throw Self.refusal(body, status: response.statusCode, model: request.model, server: server)
                    }
                    for try await line in lines {
                        for event in try Self.events(in: line, model: request.model, server: server) {
                            continuation.yield(event)
                            // The stop reason is the end of the answer, not the
                            // end of the connection: nothing after it is read,
                            // so a later record cannot replace a "length", and
                            // a server holding the connection open is not
                            // waited on.
                            if case .done = event {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translated(error, server))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func get(_ url: URL, at server: OllamaServer) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: URLRequest(url: url, timeoutInterval: 3))
        } catch {
            throw Self.translated(error, server)
        }
    }

    /// One NDJSON line of a streamed answer. Content can ride on the final
    /// line too, so it is taken before the stop reason.
    static func events(in line: String, model: String, server: OllamaServer) throws -> [ChatEvent] {
        struct Line: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
            let doneReason: String?
            let error: String?
        }
        guard line.contains(where: { !$0.isWhitespace }) else { return [] }
        guard let parsed = try? decoder.decode(Line.self, from: Data(line.utf8)) else {
            throw OllamaError.badResponse(status: 200)
        }
        if let error = parsed.error { throw refusal(error, status: 200, model: model, server: server) }
        var events: [ChatEvent] = []
        if let content = parsed.message?.content, !content.isEmpty { events.append(.text(content)) }
        if parsed.done == true { events.append(.done(reason: parsed.doneReason)) }
        return events
    }

    /// Ollama's `{"error": "..."}`, whether it came as the body of a failed
    /// response or as a line after streaming had started.
    static func refusal(_ body: String, status: Int, model: String, server: OllamaServer) -> OllamaError {
        struct Failure: Decodable { let error: String }
        let message = (try? decoder.decode(Failure.self, from: Data(body.utf8)))?.error ?? body
        // Each runner words this its own way: "the input length exceeds the
        // context length" (Ollama 0.13), "exceeds the model's maximum context
        // length" (0.40.1's MLX runner), and llama.cpp's own "exceeds the
        // available context size" passed through by 0.40.1. All mean the same.
        let lowered = message.lowercased()
        if lowered.contains("context length") || lowered.contains("context size") { return .inputTooLong }
        if status == 404, message.contains("not found") { return .modelUnavailable(name: model, host: server.displayHost) }
        return .badResponse(status: status)
    }

    static func translated(_ error: any Error, _ server: OllamaServer) -> any Error {
        switch error {
        case is CancellationError, is OllamaError:
            return error
        case let url as URLError where url.code == .cancelled:
            return CancellationError()
        case let url as URLError where url.code == .appTransportSecurityRequiresSecureConnection:
            return OllamaError.needsHTTPS(host: server.displayHost)
        case is URLError:
            return OllamaError.unreachable(host: server.displayHost)
        default:
            return OllamaError.badResponse(status: 0)
        }
    }
}
