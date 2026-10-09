import Foundation
import RewriteCore
import Testing

@testable import Engines

/// Against the real Ollama on this Mac, off unless `EVEREST_OLLAMA_LIVE=1`,
/// so the normal suite never touches the network. Uses whatever model the
/// server lists first: no model name is written down here either.
///
///   EVEREST_OLLAMA_LIVE=1 xcrun xctest .build/out/Products/Debug/EnginesTests.xctest
@Suite("Ollama, live", .enabled(if: ProcessInfo.processInfo.environment["EVEREST_OLLAMA_LIVE"] == "1"))
struct OllamaLiveTests {
    static let address = "http://localhost:11434/v1"

    /// The real server for everything except `/api/ps`, which reports a
    /// smaller window so a passage of a few thousand characters must split.
    struct SmallWindow: HTTPTransport {
        let real = URLSessionTransport()
        let model: String
        let window: Int

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.url?.path == "/api/ps" else { return try await real.data(for: request) }
            let body = #"{"models":[{"name":"\#(model)","model":"\#(model)","context_length":\#(window)}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
            try await real.lines(for: request)
        }
    }

    static func firstModel() async throws -> String {
        let status = await OllamaClient().status(at: address)
        return try #require(status.models.first, "no local model on \(address)")
    }

    static func rewrite(_ text: String, with engine: OllamaEngine) async throws -> String {
        var finished: String?
        for try await event in engine.stream(RewriteRequest(text: text, preset: .quickImprove)) {
            if case let .finished(rewrite) = event { finished = rewrite }
        }
        return try #require(finished)
    }

    @Test("the server lists local models, and a sentence comes back rewritten")
    func aSentenceRoundTrips() async throws {
        let model = try await Self.firstModel()
        let engine = OllamaEngine(client: OllamaClient(), settings: { (Self.address, model) })

        let rewrite = try await Self.rewrite("we was hoping to get your thoughts on the deck this week", with: engine)
        print("live: \(model) → \(rewrite)")
        #expect(rewrite.contains(where: { !$0.isWhitespace }))
    }

    @Test("a long passage goes in pieces and keeps its paragraph breaks")
    func aLongPassageSplits() async throws {
        let model = try await Self.firstModel()
        let paragraph = "we was looking at the numbers again last night and honestly the picture is much clearer then it was on tuesday, the drop is mostly in one group of new users rather then spread across everyone. that is a easier problem to fix, and i think we can have a plan by thursday if the team agree. "
        let text = (1...4).map { _ in String(repeating: paragraph, count: 3).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n\n")
        let transport = SmallWindow(model: model, window: 2048)
        let engine = OllamaEngine(client: OllamaClient(transport: transport), settings: { (Self.address, model) })

        let rewrite = try await Self.rewrite(text, with: engine)
        print("live: \(text.count) characters in, \(rewrite.count) out, \(rewrite.components(separatedBy: "\n\n").count) paragraphs")
        for paragraph in rewrite.components(separatedBy: "\n\n") {
            print("live:   \(paragraph.count) characters: \(paragraph.prefix(70))… \(paragraph.suffix(40))")
        }
        #expect(text.utf8.count > 3_000)
        #expect(rewrite.components(separatedBy: "\n\n").count == 4)
    }

    /// How far the bytes ÷ 3 guess sits from the server's own count, for
    /// text denser than prose. Recorded, not asserted: the guard is
    /// `truncate: false`, and this says how often it would have to act.
    @Test("the token guess against the server's count, for code and emoji")
    func estimateAgainstTheServer() async throws {
        let model = try await Self.firstModel()
        let samples = [
            "prose": String(repeating: "The drop is concentrated in one cohort rather than spread across the base. ", count: 20),
            "code": String(repeating: "let xs=[0x1F,0x2A];for(i,v)in xs.enumerated(){print(i,v,v>>2&0b11)}\n", count: 20),
            "emoji": String(repeating: "Ship it 🚀🔥👍🏽 now 🇮🇳 ok? ", count: 20),
        ]
        for (name, sample) in samples.sorted(by: { $0.key < $1.key }) {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, prompt: sample, numPredict: 1))
            let (response, lines) = try await URLSessionTransport().lines(for: request)
            #expect(response.statusCode == 200, "\(name)")
            var counted: Int?
            for try await line in lines where line.contains("prompt_eval_count") {
                counted = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["prompt_eval_count"] as? Int
            }
            let server = try #require(counted, "\(name): the server reported no prompt_eval_count")
            #expect(server > 0)
            print("live: \(name): \(sample.utf8.count) bytes, guess \(OllamaEngine.estimatedTokens(sample)), server \(server)")
        }
    }
}
