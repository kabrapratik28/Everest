import Combine
import Engines
import Foundation
import RewriteCore

/// Why a delete was refused.
public enum ModelDeletionError: Error, Equatable, Sendable {
    /// This is the model the app is set to use. There is no honest model to
    /// fall back to — the default is usually the one being deleted, and
    /// Apple's engine may not exist on this Mac — so the useful answer is to
    /// say which switch to make first.
    case inUse
}

/// The Model tab: what is installed, what it would cost to install, and a box
/// to try the selected model on without touching any real text.
@MainActor
public final class ModelSettingsModel: ObservableObject {
    public struct Row: Identifiable, Sendable {
        public let spec: ModelSpec
        public let availability: EngineAvailability
        public var id: EngineID { spec.id }
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var downloadProgress: [EngineID: Double] = [:]
    @Published public private(set) var testOutput: String?
    @Published public private(set) var testFailure: String?

    private let settings: AppSettings
    private let engineFor: @Sendable (EngineID) -> any RewriteEngine
    private let storeRoot: URL

    public init(
        settings: AppSettings,
        engineFor: @escaping @Sendable (EngineID) -> any RewriteEngine,
        storeRoot: URL = EngineFactory.modelStoreRoot
    ) {
        self.settings = settings
        self.engineFor = engineFor
        self.storeRoot = storeRoot
        rows = ModelCatalog.all.map { Row(spec: $0, availability: .needsDownload(bytes: $0.approxBytes)) }
    }

    /// Re-asks every engine what it can do right now.
    ///
    /// From `availability()`, not from files existing: `ModelStore` reports
    /// ready only once a model has actually *loaded*, and a download can
    /// complete and still leave a truncated safetensors file that fails
    /// identically on every hotkey press. Apple's engine answers differently
    /// from one call to the next, because its availability is a System
    /// Settings toggle.
    public func refresh() async {
        var next: [Row] = []
        for spec in ModelCatalog.all {
            next.append(Row(spec: spec, availability: await engineFor(spec.id).availability()))
        }
        rows = next
    }

    /// Whether this model can be removed.
    ///
    /// Never the one in use. Deleting it would leave the next hotkey press
    /// silently re-downloading gigabytes the user had just deliberately freed,
    /// and there is no honest model to fall back to: the default is usually
    /// the one being deleted, and Apple's engine may not exist on this Mac.
    /// Saying "switch first" is more use than choosing for them.
    public func canDelete(_ spec: ModelSpec) -> Bool {
        spec.repoID.isEmpty == false && spec.id != settings.engineID
    }

    /// Downloads and loads a model, reporting progress into `downloadProgress`.
    ///
    /// Values are drained from an `AsyncStream` in order for the same reason
    /// the coordinator does it: a task per callback is not ordered, and a bar
    /// that goes backwards reads as a failing download.
    public func download(_ spec: ModelSpec) async throws {
        let engine = engineFor(spec.id)
        let progress = AsyncStream<Double>.makeStream()
        let preparing = Task {
            defer { progress.continuation.finish() }
            try await engine.prepare { progress.continuation.yield($0) }
        }
        for await fraction in progress.stream {
            downloadProgress[spec.id] = fraction
        }
        defer { downloadProgress[spec.id] = nil }
        try await preparing.value
        await refresh()
    }

    /// Removes a model's weights.
    ///
    /// The refusal lives here rather than only on the button, because
    /// `disabled` is a hint to whoever is clicking, not a guard: anything that
    /// reaches this another way would take the weights out from under the next
    /// hotkey press.
    ///
    /// `ModelStore.delete` walks all four locations a repository occupies.
    /// Three of them are not under `models--org--name/`, and removing only
    /// that one looks correct — the gigabytes do go — while leaking the lock
    /// and metadata trees forever.
    public func delete(_ spec: ModelSpec) async throws {
        guard canDelete(spec) else { throw ModelDeletionError.inUse }
        try ModelStore(root: storeRoot).delete(spec.repoID)
        await refresh()
    }

    /// Runs the selected engine over the user's own sample text.
    ///
    /// Deliberately has no access to `ReplacementService` and no snapshot to
    /// write to, so there is no path from this box into a document or onto the
    /// pasteboard. It goes through the same `PromptBuilder` and the same
    /// `OutputValidator` a hotkey press does — a box that skipped either would
    /// be demonstrating something the app does not do.
    public func runTest(on sample: String) async {
        testOutput = nil
        testFailure = nil

        let engine = engineFor(settings.engineID)
        let request = RewriteRequest(text: sample, preset: settings.quickImprove)
        var finished: String?
        do {
            try await engine.prepare { _ in }
            for try await event in engine.stream(request) {
                if case let .finished(text) = event { finished = text }
            }
        } catch {
            testFailure = EngineFailure.reason(for: error)
            return
        }

        guard let finished else { return }
        switch OutputValidator.validate(finished, source: sample) {
        case let .success(text): testOutput = text
        case let .failure(failure): testFailure = failure.message
        }
    }
}
