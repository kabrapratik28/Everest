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
        /// Whether this is the engine a hotkey press would use.
        ///
        /// On the row rather than recomputed per view, so the mark and the
        /// setting cannot disagree and there is one place that decides.
        public let isSelected: Bool
        public var id: EngineID { spec.id }

        /// Bytes of RAM on this Mac, so the row can answer for itself whether
        /// the weights would fit.
        let physicalMemory: UInt64

        /// Whether this Mac can hold the weights at all.
        ///
        /// `ModelCatalog` offers the 17.2 GB option unconditionally, and on a
        /// 16 GB Mac the weights alone exceed physical memory before any KV
        /// cache — so the real outcome is severe swapping or a failed load,
        /// *after* a 17.2 GB download. Checked before the download rather
        /// than caught after it, because the download is the expensive part.
        ///
        /// The headroom is for the OS, the app and the KV cache; without it a
        /// model that exactly filled RAM would count as fitting and would
        /// still thrash. Deliberately a fixed margin rather than a ratio —
        /// what the rest of the system needs does not scale with the model.
        public var fitsInMemory: Bool {
            UInt64(max(spec.approxBytes, 0)) + Self.memoryHeadroom <= physicalMemory
        }

        /// 4 GB left for everything that is not the weights.
        static let memoryHeadroom: UInt64 = 4 * 1024 * 1024 * 1024

        /// Whether weights still have to be fetched before this can rewrite.
        ///
        /// Deliberately independent of `isSelected`. They are different facts,
        /// and conflating them is what left onboarding with no way forward:
        /// `engineID` defaults to `.qwen4B`, so the selected model on a new Mac
        /// is the uninstalled one, and a row that offered only "In use"
        /// (disabled) offered nothing at all.
        ///
        /// False for Apple's engine whatever its availability says — it has no
        /// repository, so the button could not do anything.
        public var needsDownload: Bool {
            guard fitsInMemory, case .needsDownload = availability else { return false }
            return !spec.repoID.isEmpty
        }

        /// What this model costs to install, in words.
        ///
        /// On the row so both the Model tab and onboarding say the same thing.
        /// Onboarding said nothing at all, which is the other half of the same
        /// dead end: a disabled button and no explanation.
        public var installSummary: String {
            // Ahead of install state on purpose: a model that cannot run on
            // this Mac reporting "Installed" would be the most misleading
            // thing the row could say.
            guard fitsInMemory else {
                let needed = Measurement(
                    value: Double(spec.approxBytes) + Double(Self.memoryHeadroom),
                    unit: UnitInformationStorage.bytes
                )
                return "Needs about \(needed.formatted(.byteCount(style: .memory))) of memory — this Mac has less."
            }
            return switch availability {
            case .ready:
                "Installed"
            case let .needsDownload(bytes):
                spec.repoID.isEmpty
                    ? "No download needed"
                    : "\(Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).formatted(.byteCount(style: .file))) to download"
            case let .unavailable(reason):
                reason
            }
        }
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var downloadProgress: [EngineID: Double] = [:]
    /// Why a download stopped, per model. Cleared when one is retried.
    @Published public private(set) var downloadFailure: [EngineID: String] = [:]
    @Published public private(set) var testOutput: String?
    @Published public private(set) var testFailure: String?

    private let settings: AppSettings
    private let engineFor: @Sendable (EngineID) -> any RewriteEngine
    private let storeRoot: URL
    private let physicalMemory: UInt64

    public init(
        settings: AppSettings,
        engineFor: @escaping @Sendable (EngineID) -> any RewriteEngine,
        storeRoot: URL = EngineFactory.modelStoreRoot,
        // Measured, not assumed. Injected so a test can ask what a 16 GB Mac
        // is told without being run on one.
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.settings = settings
        self.engineFor = engineFor
        self.storeRoot = storeRoot
        self.physicalMemory = physicalMemory
        rows = ModelCatalog.all.map {
            Row(
                spec: $0,
                availability: .needsDownload(bytes: $0.approxBytes),
                isSelected: $0.id == settings.engineID,
                physicalMemory: physicalMemory
            )
        }
    }

    /// Chooses the engine every rewrite will use.
    ///
    /// The row is the control, so this is what the row calls. There was a
    /// separate "Use" button beside a drawn circle, which meant the picture of
    /// a radio button and the thing that actually moved the setting were two
    /// different controls — and only one of them was clickable.
    public func select(_ id: EngineID) {
        settings.engineID = id
        rows = rows.map {
            Row(
                spec: $0.spec,
                availability: $0.availability,
                isSelected: $0.spec.id == id,
                physicalMemory: physicalMemory
            )
        }
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
            next.append(
                Row(
                    spec: spec,
                    availability: await engineFor(spec.id).availability(),
                    isSelected: spec.id == settings.engineID,
                    physicalMemory: physicalMemory
                )
            )
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

    /// Downloads and loads a model, reporting progress into `downloadProgress`
    /// and any failure into `downloadFailure`.
    ///
    /// Values are drained from an `AsyncStream` in order for the same reason
    /// the coordinator does it: a task per callback is not ordered, and a bar
    /// that goes backwards reads as a failing download.
    ///
    /// **Does not throw.** Both call sites used `try?` and swallowed the
    /// error, leaving a user whose download had failed with a bar that
    /// vanished, an unchanged status line and no way to tell "finished" from
    /// "gave up" — so they retried the same failure forever. The only consumer
    /// of this error is a label, and a recorded failure is one a caller cannot
    /// forget to show.
    public func download(_ spec: ModelSpec) async {
        downloadFailure[spec.id] = nil
        let engine = engineFor(spec.id)
        let progress = AsyncStream<Double>.makeStream()
        let preparing = Task {
            defer { progress.continuation.finish() }
            try await engine.prepare { progress.continuation.yield($0) }
        }
        for await fraction in progress.stream {
            downloadProgress[spec.id] = fraction
        }
        downloadProgress[spec.id] = nil
        do {
            try await preparing.value
        } catch {
            downloadFailure[spec.id] = EngineFailure.reason(for: error)
            return
        }
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
