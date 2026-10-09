import Foundation
import Testing

@testable import Engines

@Suite("OllamaClient")
struct OllamaClientTests {
    static let server = OllamaServer("http://localhost:11434/v1")!
    static func request(_ prompt: String = "prompt", numPredict: Int = 64) -> ChatRequest {
        ChatRequest(model: "qwen3:14b", prompt: prompt, numPredict: numPredict)
    }

    /// A cloud model runs on ollama.com, so picking one would send the
    /// selection there. The user asked for their offline models only.
    @Test("the model list keeps the server's order and leaves out cloud models")
    func localModelsLeaveOutCloudModels() async throws {
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b", "gpt-oss:120b-cloud", "llama3.2:3b"], cloud: ["gpt-oss:120b-cloud"]))

        #expect(try await OllamaClient(transport: transport).localModels(at: Self.server) == ["qwen3:14b", "llama3.2:3b"])
    }

    @Test("network failures name the user's host; macOS's https refusal and cancellation keep their own meaning")
    func transportErrorsAreTranslated() async {
        func failure(_ code: URLError.Code) async -> (any Error)? {
            let client = OllamaClient(transport: ScriptedTransport(tags: .init(error: URLError(code))))
            do {
                _ = try await client.localModels(at: Self.server)
                return nil
            } catch {
                return error
            }
        }
        #expect(await failure(.cannotConnectToHost) as? OllamaError == .unreachable(host: "localhost:11434"))
        #expect(await failure(.appTransportSecurityRequiresSecureConnection) as? OllamaError == .needsHTTPS(host: "localhost:11434"))
        #expect(await failure(.cancelled) is CancellationError)
    }

    @Test("status is ready with models, or unavailable with a reason the user can act on")
    func statusDescribesTheServer() async {
        let ready = await OllamaClient(transport: ScriptedTransport(tags: .tags(["qwen3:14b"]))).status(at: "http://localhost:11434/v1")
        #expect(ready == OllamaStatus(models: ["qwen3:14b"], availability: .ready))

        let empty = await OllamaClient(transport: ScriptedTransport(tags: .tags([]))).status(at: "http://localhost:11434/v1")
        #expect(empty.models.isEmpty)
        #expect(Self.reason(empty)?.contains("ollama pull") == true)

        let down = await OllamaClient(transport: ScriptedTransport(tags: .init(error: URLError(.cannotConnectToHost))))
            .status(at: "http://10.0.0.5:11434/v1")
        #expect(Self.reason(down) == OllamaError.unreachable(host: "10.0.0.5:11434").rowStatus)
        #expect(Self.reason(down)?.contains("10.0.0.5:11434") == true)

        let typo = await OllamaClient(transport: ScriptedTransport()).status(at: "localhost")
        #expect(Self.reason(typo) == OllamaError.invalidAddress.rowStatus)
    }

    static func reason(_ status: OllamaStatus) -> String? {
        if case let .unavailable(reason) = status.availability { return reason }
        return nil
    }

    @Test("the context window is the running model's own, or unknown")
    func contextWindowIsTheRunningModels() async throws {
        let running = OllamaClient(transport: ScriptedTransport(ps: .ps("qwen3:14b", context: 8192)))
        #expect(try await running.contextWindow(for: "qwen3:14b", at: Self.server) == 8192)
        #expect(try await running.contextWindow(for: "llama3.2:3b", at: Self.server) == nil)

        let down = OllamaClient(transport: ScriptedTransport(ps: .init(error: URLError(.cannotConnectToHost))))
        #expect(try await down.contextWindow(for: "qwen3:14b", at: Self.server) == nil)
    }

    /// Without `truncate: false` Ollama keeps a prompt's first few tokens and
    /// discards the ones after them, which is where the safety frame sits.
    @Test("a chat request asks for no thinking, no silent truncation and no context shift")
    func chatRequestCarriesTheSafetyFlags() async throws {
        let transport = ScriptedTransport(chat: [.chat(["Fixed."])])
        for try await _ in OllamaClient(transport: transport).chat(Self.request("PROMPT", numPredict: 321), at: Self.server) {}

        let body = try #require(transport.chatBodies.first)
        #expect(transport.chatRequests.first?.httpMethod == "POST")
        #expect(body.model == "qwen3:14b")
        #expect(body.messages == [ChatBody.Message(role: "user", content: "PROMPT")])
        #expect(body.stream && !body.think && !body.truncate && !body.shift)
        #expect(body.options.numPredict == 321)
        #expect(abs(body.options.temperature - 0.2) < 1e-6)
    }

    /// Ollama unloads a model five idle minutes after its last request unless
    /// the request or the server says otherwise, and reloading `gemma4:26b`
    /// took 6.7 to 11.4 s (measured 2026-10-09). On the Mac app the server's
    /// setting is `launchctl setenv OLLAMA_KEEP_ALIVE`, read only at launch
    /// and gone on reboot, so every request asks for a day: a workday's gaps
    /// stay warm, and the model is asked to unload a day after the last rewrite.
    @Test("a chat request asks Ollama to keep the model loaded for a day")
    func chatRequestKeepsTheModelLoadedForADay() async throws {
        let transport = ScriptedTransport(chat: [.chat(["Fixed."])])
        for try await _ in OllamaClient(transport: transport).chat(Self.request("PROMPT", numPredict: 321), at: Self.server) {}

        let body = try #require(transport.chatBodies.first)
        #expect(body.keepAlive == "24h")
    }

    @Test("streamed content arrives as text, thinking and blank lines are dropped, and the stop reason ends it")
    func chatStreamsContentOnly() async throws {
        var reply = ScriptedTransport.Reply.chat(["Fixed", " this", "."])
        reply.lines.insert(#"{"model":"qwen3:14b","created_at":"2026-10-08T22:27:45.839062Z","message":{"role":"assistant","content":"","thinking":"Okay"},"done":false}"#, at: 0)
        reply.lines.insert("", at: 2)

        var events: [ChatEvent] = []
        for try await event in OllamaClient(transport: ScriptedTransport(chat: [reply])).chat(Self.request(), at: Self.server) {
            events.append(event)
        }
        #expect(events == [.text("Fixed"), .text(" this"), .text("."), .done(reason: "stop")])
    }

    /// A record after the stop reason is not part of the answer, and could
    /// overwrite a "length" with a "stop". Nor is the end of the connection
    /// the end of the answer: a server may hold it open.
    @Test("the stop reason ends the answer: nothing after it is read, and an open connection is not waited on", .timeLimit(.minutes(1)))
    func theStopReasonEndsTheAnswer() async throws {
        var trailing = ScriptedTransport.Reply.chat(["Half"], doneReason: "length")
        trailing.lines += ScriptedTransport.Reply.chat([" more"], doneReason: "stop").lines
        var events: [ChatEvent] = []
        for try await event in OllamaClient(transport: ScriptedTransport(chat: [trailing])).chat(Self.request(), at: Self.server) {
            events.append(event)
        }
        #expect(events == [.text("Half"), .done(reason: "length")])

        var open = ScriptedTransport.Reply.chat(["Done."])
        open.lines.append("")
        open.holdsAfterLine = 1
        var answered: [ChatEvent] = []
        for try await event in OllamaClient(transport: ScriptedTransport(chat: [open])).chat(Self.request(), at: Self.server) {
            answered.append(event)
        }
        #expect(answered == [.text("Done."), .done(reason: "stop")])
    }

    @Test("Ollama's refusals become errors the user can act on")
    func chatFailuresAreMapped() async {
        func failure(_ reply: ScriptedTransport.Reply) async -> OllamaError? {
            do {
                for try await _ in OllamaClient(transport: ScriptedTransport(chat: [reply])).chat(Self.request(), at: Self.server) {}
                return nil
            } catch {
                return error as? OllamaError
            }
        }
        #expect(await failure(.failure(404, "model 'qwen3:14b' not found")) == .modelUnavailable(name: "qwen3:14b", host: "localhost:11434"))
        // The same refusal in each runner's words: Ollama 0.13's runners, then
        // 0.40.1's MLX runner (`mlxrunner/pipeline.go`) and its llama.cpp
        // server, which passes llama.cpp's own message through.
        #expect(await failure(.failure(400, "the input length exceeds the context length")) == .inputTooLong)
        #expect(await failure(.failure(500, "input length (40012 tokens) exceeds the model's maximum context length (32768 tokens)")) == .inputTooLong)
        #expect(await failure(.failure(400, "the request exceeds the available context size, try increasing it")) == .inputTooLong)
        #expect(await failure(.failure(500, "llama runner process has terminated")) == .badResponse(status: 500))

        var midStream = ScriptedTransport.Reply.chat(["Half"], doneReason: nil)
        midStream.lines.append(#"{"error":"the input length exceeds the context length"}"#)
        #expect(await failure(midStream) == .inputTooLong)
    }

    @Test("a consumer that stops listening stops the request behind it", .timeLimit(.minutes(1)))
    func cancellingTheConsumerStopsTheProducer() async throws {
        var complete: [ChatEvent] = []
        for try await event in OllamaClient(transport: ScriptedTransport(chat: [.chat(["a", "b", "c"])])).chat(Self.request(), at: Self.server) {
            complete.append(event)
        }
        #expect(complete.count == 4)

        var held = ScriptedTransport.Reply.chat(["a", "b", "c"])
        held.holdsAfterLine = 0
        let transport = ScriptedTransport(chat: [held])
        for try await _ in OllamaClient(transport: transport).chat(Self.request(), at: Self.server) { break }
        await transport.waitUntilProducerCancelled()
    }

    /// `PRIVACY.md` says Everest never writes a selection or a rewrite to
    /// disk. `URLSession.shared` keeps a disk cache, cookies and credentials.
    @Test("the production transport keeps nothing on disk")
    func productionTransportIsEphemeral() {
        let configuration = URLSessionTransport().session.configuration

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }

    @Test("no Ollama message contains an em dash")
    func messagesHaveNoEmDash() {
        let errors: [OllamaError] = [
            .invalidAddress, .unreachable(host: "h"), .needsHTTPS(host: "h"), .noModelChosen,
            .modelUnavailable(name: "m", host: "h"), .contextTooSmall(window: 512), .inputTooLong,
            .wordTooLong, .badResponse(status: 500), .interrupted,
        ]
        for error in errors {
            #expect(!error.message.contains("\u{2014}") && !error.rowStatus.contains("\u{2014}"), "\(error)")
        }
    }
}
