import Foundation
import RewriteCore
import Testing

@testable import Engines

@Suite("OllamaEngine")
struct OllamaEngineTests {
    struct Outcome {
        var snapshots: [String] = []
        var finished: String?
        var error: (any Error)?
    }

    static func engine(_ transport: ScriptedTransport, model: String = "qwen3:14b") -> OllamaEngine {
        OllamaEngine(client: OllamaClient(transport: transport), settings: { ("http://localhost:11434/v1", model) })
    }

    static func run(_ engine: OllamaEngine, _ text: String, onSnapshot: @Sendable () -> Void = {}) async -> Outcome {
        var outcome = Outcome()
        do {
            for try await event in engine.stream(RewriteRequest(text: text, preset: .quickImprove)) {
                switch event {
                case let .outputSnapshot(text):
                    outcome.snapshots.append(text)
                    onSnapshot()
                case let .finished(text): outcome.finished = text
                case .preparing: break
                }
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    /// Three paragraphs of about 715 bytes. At a 2,048-token window a piece
    /// holds about 846 bytes, so each paragraph becomes one piece.
    static let paragraphs = (1...3).map {
        String(repeating: "Paragraph \($0) carries a steady line of ordinary prose. ", count: 13).trimmingCharacters(in: .whitespaces)
    }

    @Test("content streams as growing snapshots and the selection's own edge whitespace survives")
    func streamsAndKeepsEdges() async throws {
        // Models often add a newline at either end. The selection's own edges
        // go back around the rewrite; the model's are dropped.
        var reply = ScriptedTransport.Reply.chat(["\nFixed", " this.\n"])
        reply.lines.insert(#"{"model":"qwen3:14b","created_at":"2026-10-08T22:27:45.839062Z","message":{"role":"assistant","content":"","thinking":"Okay"},"done":false}"#, at: 0)
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [reply])

        let outcome = await Self.run(Self.engine(transport), "  fix this\n")

        #expect(outcome.error == nil)
        #expect(outcome.snapshots == ["  \nFixed", "  \nFixed this.\n"])
        #expect(outcome.finished == "  Fixed this.\n")
        let body = try #require(transport.chatBodies.first)
        #expect(body.model == "qwen3:14b")
        #expect(body.messages.first?.content.contains("\nfix this\n") == true)
        #expect(body.messages.first?.content.contains("is part") == false)
    }

    /// The saved name can stop being a local model: switched servers, a model
    /// removed, or a name that runs on ollama.com. Nothing is sent then.
    @Test("a saved model that is not local on this server sends nothing")
    func cloudModelsAreRefusedBeforeSending() async throws {
        let cloud = ScriptedTransport(tags: .tags(["qwen3:14b", "gpt-oss:120b-cloud"], cloud: ["gpt-oss:120b-cloud"]), chat: [.chat(["x"])])
        let refused = await Self.run(Self.engine(cloud, model: "gpt-oss:120b-cloud"), "fix this")
        #expect(refused.error as? OllamaError == .modelUnavailable(name: "gpt-oss:120b-cloud", host: "localhost:11434"))
        #expect(cloud.chatRequests.isEmpty)

        let local = ScriptedTransport(tags: .tags(["qwen3:14b", "gpt-oss:120b-cloud"]), chat: [.chat(["x"])])
        _ = await Self.run(Self.engine(local, model: "gpt-oss:120b-cloud"), "fix this")
        #expect(local.chatRequests.count == 1)
    }

    @Test("an answer cut off by its budget, or one that never says it finished, is not a rewrite")
    func unfinishedAnswersAreRefused() async {
        let truncated = await Self.run(Self.engine(ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [.chat(["Fixed th"], doneReason: "length")])), "fix this")
        #expect(truncated.error as? GenerationError == .truncated)
        #expect(truncated.finished == nil)

        let dropped = await Self.run(Self.engine(ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [.chat(["Fixed th"], doneReason: nil)])), "fix this")
        #expect(dropped.error as? OllamaError == .interrupted)
        #expect(dropped.finished == nil)
    }

    @Test("a long selection goes in pieces that each fit the window, each told its place, and joins back with the user's own breaks")
    func longSelectionsGoInPieces() async throws {
        let text = Self.paragraphs.joined(separator: "\n\n")
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [.echo])

        let outcome = await Self.run(Self.engine(transport), text)

        #expect(outcome.error == nil)
        #expect(outcome.finished.map { Array($0.utf8) } == Array(text.utf8))
        let bodies = transport.chatBodies
        #expect(bodies.count == 3)
        for (number, body) in bodies.enumerated() {
            let prompt = try #require(body.messages.first?.content)
            #expect(prompt.contains("part \(number + 1) of 3"))
            #expect((prompt.utf8.count + 2) / 3 + 64 + body.options.numPredict <= 2048, "piece \(number + 1) overruns the window")
        }
        let afterFirst = outcome.snapshots.drop { !$0.hasPrefix(Self.paragraphs[0] + "\n\n") }
        #expect(!afterFirst.isEmpty && afterFirst.allSatisfy { $0.hasPrefix(Self.paragraphs[0] + "\n\n") })
    }

    /// The fence is longer than a piece, so it must be cut at its blank line,
    /// and the second piece starts inside code. Typography decides what is
    /// code by counting backticks, so run per piece it would turn
    /// `b = 2 -- c` into `b = 2, c`.
    @Test("code split across pieces keeps its text through joining and final validation")
    func codeAcrossPiecesIsUntouched() async throws {
        let half = (1...18).map { "let value\($0) = compute(\($0)) // step \($0)" }.joined(separator: "\n")
        let fence = "```\n" + half + "\n\nb = 2 -- c\n" + half + "\n```"
        let text = "Here is the script we ran.\n\n" + fence + "\n\nIt finished in a minute."
        #expect(fence.utf8.count > 1_100)
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [.echo])

        let outcome = await Self.run(Self.engine(transport), text)

        #expect(transport.chatRequests.count >= 2)
        let finished = try #require(outcome.finished)
        #expect(finished.contains("b = 2 -- c"))
        #expect(try OutputValidator.validate(finished, source: text).get().contains("b = 2 -- c"))
    }

    @Test("a window too small for Everest's own prompt refuses before sending anything")
    func tooSmallWindowsAreRefused() async {
        let small = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 512), chat: [.echo])
        let refused = await Self.run(Self.engine(small), "fix this")
        #expect(refused.error as? OllamaError == .contextTooSmall(window: 512))
        #expect(small.chatRequests.isEmpty)

        let roomy = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [.echo])
        _ = await Self.run(Self.engine(roomy), "fix this")
        #expect(roomy.chatRequests.count == 1)
    }

    @Test("a word longer than any piece refuses before sending anything")
    func overlongWordsAreRefused() async {
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [.echo])
        let outcome = await Self.run(Self.engine(transport), "See " + String(repeating: "x", count: 20_000))

        #expect(outcome.error as? OllamaError == .wordTooLong)
        #expect(transport.chatRequests.isEmpty)
    }

    @Test("a blank piece stops the whole rewrite and asks for no more pieces")
    func blankPiecesStopEverything() async {
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [.chat(["   "]), .echo])
        let outcome = await Self.run(Self.engine(transport), Self.paragraphs.joined(separator: "\n\n"))

        #expect(outcome.error as? ValidationFailure == .empty)
        #expect(outcome.finished == nil)
        #expect(transport.chatRequests.count == 1)
    }

    @Test("with no model chosen nothing is asked of the server")
    func noModelNoRequests() async {
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [.echo])
        let outcome = await Self.run(Self.engine(transport, model: ""), "fix this")
        #expect(outcome.error as? OllamaError == .noModelChosen)
        #expect(transport.requests.isEmpty)

        _ = await Self.run(Self.engine(transport), "fix this")
        #expect(transport.chatRequests.count == 1)
    }

    @Test("cancelled before the request goes out, nothing is sent", .timeLimit(.minutes(1)))
    func cancelBeforeSending() async {
        var heldTags = ScriptedTransport.Reply.tags(["qwen3:14b"])
        heldTags.holdsHeaders = true

        let control = ScriptedTransport(tags: heldTags, chat: [.echo])
        let running = Task { await Self.run(Self.engine(control), "fix this") }
        control.release()
        #expect(await running.value.finished == "fix this")
        #expect(control.chatRequests.count == 1)

        let transport = ScriptedTransport(tags: heldTags, chat: [.echo])
        let engine = Self.engine(transport)
        let cancelled = Task { await Self.run(engine, "fix this") }
        while transport.requests.isEmpty { await Task.yield() }
        await engine.cancel()
        transport.release()
        let outcome = await cancelled.value
        #expect(outcome.finished == nil && outcome.error == nil)
        #expect(transport.chatRequests.isEmpty)
    }

    @Test("cancelled while the answer is awaited, the request is stopped", .timeLimit(.minutes(1)))
    func cancelWhileWaitingForTheAnswer() async {
        var held = ScriptedTransport.Reply.echo
        held.holdsHeaders = true
        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), chat: [held])
        let engine = Self.engine(transport)

        let cancelled = Task { await Self.run(engine, "fix this") }
        while transport.chatRequests.isEmpty { await Task.yield() }
        await engine.cancel()
        await transport.waitUntilProducerCancelled()
        let outcome = await cancelled.value
        #expect(outcome.finished == nil && outcome.error == nil)
    }

    /// Cancelled after the first piece has started arriving, not merely
    /// after its request went out: the held fixture finishes when released,
    /// and the cancelled run is cut only once a snapshot has been seen.
    @Test("cancelled mid-stream, the request is stopped and no later piece is asked for", .timeLimit(.minutes(1)))
    func cancelMidStream() async {
        var held = ScriptedTransport.Reply.chat([Self.paragraphs[0]])
        held.holdsAfterLine = 0
        let text = Self.paragraphs.joined(separator: "\n\n")

        let released = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [held, .echo])
        let running = Task { await Self.run(Self.engine(released), text) }
        while released.chatRequests.isEmpty { await Task.yield() }
        released.release()
        #expect(await running.value.finished != nil)

        let transport = ScriptedTransport(tags: .tags(["qwen3:14b"]), ps: .ps("qwen3:14b", context: 2048), chat: [held, .echo])
        let engine = Self.engine(transport)
        let snapshot = AsyncStream<Void>.makeStream()
        let cancelled = Task { await Self.run(engine, text) { snapshot.continuation.yield(()) } }
        var seen = snapshot.stream.makeAsyncIterator()
        _ = await seen.next()
        await engine.cancel()
        await transport.waitUntilProducerCancelled()
        let outcome = await cancelled.value
        #expect(!outcome.snapshots.isEmpty)
        #expect(outcome.finished == nil && outcome.error == nil)
        #expect(transport.chatRequests.count == 1)
    }
}
