import Combine
import Engines
import Foundation
import RewriteCore
import Testing
import os

@testable import AppCore

/// Holds each status request until the test answers it, so answers can
/// arrive in any order.
final class StatusGate: Sendable {
    private let pending = OSAllocatedUnfairLock<[String: CheckedContinuation<OllamaStatus, Never>]>(initialState: [:])

    func status(for address: String) async -> OllamaStatus {
        await withCheckedContinuation { continuation in pending.withLock { $0[address] = continuation } }
    }

    func isWaiting(for address: String) -> Bool { pending.withLock { $0[address] != nil } }

    func answer(_ address: String, with status: OllamaStatus) {
        pending.withLock { $0.removeValue(forKey: address) }?.resume(returning: status)
    }
}

@MainActor
@Suite("Model tab: Ollama")
struct OllamaSettingsTests {
    nonisolated static func ready(_ models: [String]) -> OllamaStatus { OllamaStatus(models: models, availability: .ready) }

    static func model(_ settings: AppSettings, status: @escaping @Sendable (String) async -> OllamaStatus) -> ModelSettingsModel {
        ModelSettingsModel(settings: settings, engineFor: { StubEngine(id: $0) }, ollamaStatus: status)
    }

    static func waitUntil(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    /// Every row starts as "needs download", which for an engine with no
    /// repository reads as choosable. Ollama has to have answered first.
    @Test("the Ollama row cannot be chosen until the server has answered with models")
    func chosenOnlyAfterTheServerAnswers() async {
        let settings = makeSettings()
        let model = Self.model(settings) { _ in Self.ready(["qwen3:14b"]) }

        model.select(.ollama)
        #expect(settings.engineID == .qwen4B)

        await model.refreshOllama()
        model.select(.ollama)
        #expect(settings.engineID == .ollama)
    }

    @Test("one answer fills the list and the row together; an unavailable server empties the list and says why")
    func discoveryPublishesListAndStatusTogether() async {
        let current = OSAllocatedUnfairLock(initialState: Self.ready(["qwen3:14b", "llama3.2:3b"]))
        let model = Self.model(makeSettings()) { _ in current.withLock { $0 } }

        await model.refreshOllama()
        #expect(model.ollamaModels == ["qwen3:14b", "llama3.2:3b"])
        #expect(model.ollamaSummary == "Connected, 2 models")

        current.withLock { $0 = Self.ready(["qwen3:14b"]) }
        await model.refreshOllama()
        #expect(model.ollamaSummary == "Connected, 1 model")

        current.withLock { $0 = OllamaStatus(models: [], availability: .unavailable(reason: "Can't reach Ollama at localhost:11434. Open Ollama, then press ↻.")) }
        await model.refreshOllama()
        #expect(model.ollamaModels.isEmpty)
        #expect(model.ollamaSummary == "Can't reach Ollama at localhost:11434. Open Ollama, then press ↻.")
    }

    /// Onboarding refreshes the rows it shows. Asking Ollama there would be
    /// a request the user never asked for, and for an address on another
    /// computer, a Local Network permission prompt out of nowhere.
    @Test("refreshing the rows asks Ollama nothing; discovery asks once")
    func onlyDiscoveryAsksOllama() async {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let model = Self.model(makeSettings()) { address in
            asked.withLock { $0.append(address) }
            return Self.ready(["qwen3:14b"])
        }

        await model.refresh()
        #expect(asked.withLock { $0 }.isEmpty)

        await model.refreshOllama()
        #expect(asked.withLock { $0 } == ["http://localhost:11434/v1"])
    }

    /// Ready means a rewrite would go through: the server answers and still
    /// has the saved model. A server up without it sent Continue on to a
    /// rewrite that refuses.
    @Test("Ollama counts as ready only while the server still has the saved model")
    func readyNeedsTheSavedModel() async {
        let settings = makeSettings()
        settings.engineID = .ollama
        settings.ollamaModel = "mistral:7b"
        let model = Self.model(settings) { _ in Self.ready(["qwen3:14b"]) }
        await model.refreshOllama()
        #expect(model.isSelectedEngineReady == false)

        settings.ollamaModel = "qwen3:14b"
        #expect(model.isSelectedEngineReady)
    }

    /// The model step says where text goes. With Ollama chosen in Settings
    /// before setup finished, "nothing is sent anywhere" was false for a
    /// server on another computer.
    @Test("the setup screen's privacy line is true for the engine in use")
    func onboardingPrivacyLineMatchesTheEngine() {
        let settings = makeSettings()
        let model = Self.model(settings) { _ in Self.ready([]) }
        #expect(model.onboardingPrivacyLine == "It runs on this Mac. Nothing you rewrite is sent anywhere.")

        settings.engineID = .ollama
        #expect(model.onboardingPrivacyLine == "Ollama is selected in Settings ▸ Model, and it runs on this Mac, so nothing you rewrite leaves it.")

        settings.ollamaServer = "http://192.168.1.20:11434/v1"
        #expect(model.onboardingPrivacyLine == "Ollama is selected in Settings ▸ Model, so what you rewrite is sent to 192.168.1.20:11434.")
    }

    /// Setup's hint asks for a download, which is not what Ollama needs.
    @Test("with Ollama in use and not ready, the hint says why")
    func ollamaInUseHintSaysWhy() async {
        let settings = makeSettings()
        let current = OSAllocatedUnfairLock(initialState: OllamaStatus(models: [], availability: .unavailable(reason: "Can't reach Ollama at localhost:11434. Open Ollama, then press ↻.")))
        let model = Self.model(settings) { _ in current.withLock { $0 } }
        #expect(model.ollamaInUseHint == nil)

        settings.engineID = .ollama
        await model.refreshOllama()
        #expect(model.ollamaInUseHint == "Can't reach Ollama at localhost:11434. Open Ollama, then press ↻.")

        current.withLock { $0 = Self.ready(["qwen3:14b"]) }
        settings.ollamaModel = "mistral:7b"
        await model.refreshOllama()
        #expect(model.ollamaInUseHint == "Choose a model for Ollama in Settings ▸ Model.")

        settings.ollamaModel = "qwen3:14b"
        #expect(model.ollamaInUseHint == nil)
    }

    /// Ollama chosen in Settings before setup finished: setup must see
    /// whether it works. Asking is expected then, because the user chose it.
    @Test("with Ollama the engine in use, refreshing the rows asks it")
    func refreshAsksOllamaWhenItIsInUse() async {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let settings = makeSettings()
        settings.engineID = .ollama
        settings.ollamaModel = "qwen3:14b"
        let model = Self.model(settings) { _ in
            asked.withLock { $0 += 1 }
            return Self.ready(["qwen3:14b"])
        }

        await model.refresh()

        #expect(asked.withLock { $0 } == 1)
        #expect(model.isSelectedEngineReady)
    }

    @Test("a slow answer for an old address never replaces the answer for the new one", .timeLimit(.minutes(1)))
    func staleAnswersAreDropped() async {
        let gate = StatusGate()
        let model = Self.model(makeSettings()) { await gate.status(for: $0) }
        let old = "http://10.0.0.1:11434/v1"
        let new = "http://10.0.0.2:11434/v1"

        let first = Task { await model.setOllamaServer(old) }
        await Self.waitUntil { gate.isWaiting(for: old) }
        let second = Task { await model.setOllamaServer(new) }
        await Self.waitUntil { gate.isWaiting(for: new) }

        gate.answer(new, with: Self.ready(["new-model"]))
        await second.value
        gate.answer(old, with: Self.ready(["old-model-a", "old-model-b"]))
        await first.value

        #expect(model.ollamaServer == new)
        #expect(model.ollamaModels == ["new-model"])
        #expect(model.ollamaSummary == "Connected, 1 model")
    }

    @Test("an emptied server field goes back to the default; a new address is trimmed, and the old list goes at once", .timeLimit(.minutes(1)))
    func serverEditsNormaliseAndClear() async {
        let gate = StatusGate()
        let settings = makeSettings()
        let model = Self.model(settings) { await gate.status(for: $0) }

        let typed = Task { await model.setOllamaServer("   ") }
        await Self.waitUntil { gate.isWaiting(for: "http://localhost:11434/v1") }
        #expect(settings.ollamaServer == "http://localhost:11434/v1")
        gate.answer("http://localhost:11434/v1", with: Self.ready(["qwen3:14b"]))
        await typed.value
        #expect(model.ollamaModels == ["qwen3:14b"])

        let moved = Task { await model.setOllamaServer(" http://10.0.0.5:11434/v1 ") }
        await Self.waitUntil { gate.isWaiting(for: "http://10.0.0.5:11434/v1") }
        #expect(settings.ollamaServer == "http://10.0.0.5:11434/v1")
        #expect(model.ollamaModels.isEmpty)
        #expect(model.ollamaSummary == "Checking Ollama…")
        gate.answer("http://10.0.0.5:11434/v1", with: Self.ready(["llama3.2:3b"]))
        await moved.value
        #expect(model.ollamaModels == ["llama3.2:3b"])
    }

    @Test("choosing Ollama with no model saved takes the first listed; a saved model is never swapped, even when missing")
    func choosingOllamaKeepsTheUsersModel() async {
        let empty = makeSettings()
        let first = Self.model(empty) { _ in Self.ready(["qwen3:14b", "llama3.2:3b"]) }
        await first.refreshOllama()
        first.select(.ollama)
        #expect(empty.ollamaModel == "qwen3:14b")

        let kept = makeSettings()
        kept.ollamaModel = "llama3.2:3b"
        let second = Self.model(kept) { _ in Self.ready(["qwen3:14b", "llama3.2:3b"]) }
        await second.refreshOllama()
        second.select(.ollama)
        #expect(kept.ollamaModel == "llama3.2:3b")
        #expect(second.ollamaPickerSelection == "llama3.2:3b")

        let gone = makeSettings()
        gone.ollamaModel = "mistral:7b"
        let third = Self.model(gone) { _ in Self.ready(["qwen3:14b"]) }
        await third.refreshOllama()
        third.select(.ollama)
        #expect(gone.ollamaModel == "mistral:7b")
        #expect(third.ollamaPickerSelection == "")
    }

    @Test("only a listed model can be chosen, and choosing one refreshes the screen")
    func onlyListedModelsCanBeChosen() async {
        let settings = makeSettings()
        let model = Self.model(settings) { _ in Self.ready(["qwen3:14b", "llama3.2:3b"]) }
        await model.refreshOllama()
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }

        model.chooseOllamaModel("not-listed")
        #expect(settings.ollamaModel == "")

        model.chooseOllamaModel("llama3.2:3b")
        #expect(settings.ollamaModel == "llama3.2:3b")
        #expect(changes >= 1)
    }

    @Test("only a server on this Mac goes without the warning")
    func theWarningIsForOtherComputers() {
        let settings = makeSettings()
        let model = Self.model(settings) { _ in Self.ready([]) }
        #expect(model.ollamaServerIsOnThisMac)

        settings.ollamaServer = "http://192.168.1.20:11434/v1"
        #expect(model.ollamaServerIsOnThisMac == false)
    }

    @Test("onboarding offers every engine except Ollama; the Model tab offers them all")
    func onboardingLeavesOutOllama() {
        let model = Self.model(makeSettings()) { _ in Self.ready([]) }

        #expect(model.onboardingRows.map(\.id) == ModelCatalog.all.map(\.id).filter { $0 != .ollama })
        #expect(model.rows.map(\.id).contains(.ollama))
    }
}
