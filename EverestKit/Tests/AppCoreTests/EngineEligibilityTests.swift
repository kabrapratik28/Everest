import Foundation
import RewriteCore
import Testing

@testable import AppCore

private let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024

/// An engine the machine cannot run must not be selectable, and the refusal
/// has to be in the method rather than only on the disabled row.
///
/// Same shape as the radio button: the control that *looked* like the gate
/// and the thing that actually gated were different objects. `disabled` is a
/// hint to whoever is clicking — a keyboard path, onboarding, a later view —
/// and `select` wrote any id it was handed.
///
/// Availability counts as well as memory. Apple Intelligence reports
/// `.unavailable` when it is switched off in System Settings, and that row
/// was still selectable because only `fitsInMemory` disabled it.
@Test("an engine this Mac cannot run is refused by select, not just by the row")
@MainActor
func anIneligibleEngineCannotBeSelected() async {
    let settings = makeSettings()
    settings.engineID = .qwen4B
    let availability: [EngineID: EngineAvailability] = [
        .qwen4B: .ready,
        .qwen30B: .ready,
        .apple: .unavailable(reason: "Apple Intelligence is turned off."),
    ]
    let model = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0, availability: availability[$0] ?? .ready) },
        physicalMemory: sixteenGB
    )
    await model.refresh()
    let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })

    #expect(rows[.qwen4B]!.isEligible)
    #expect(rows[.qwen30B]!.isEligible == false, "17.2 GB does not fit in 16")
    #expect(rows[.apple]!.isEligible == false, "unavailable is not eligible either")

    model.select(.qwen30B)
    #expect(settings.engineID == .qwen4B, "a model too large for this Mac was selected")

    model.select(.apple)
    #expect(settings.engineID == .qwen4B, "an unavailable engine was selected")
}

/// A persisted id outlives the screen that offered it.
///
/// The disabled row is a view and does not exist at launch. `engineID` is
/// read straight out of `UserDefaults` and handed to `RewriteCoordinator`, so
/// a 30B choice made on a big Mac — or restored onto a smaller one, or
/// written before the memory gate existed — reaches the engine having met no
/// gate at all. Every hotkey press then loads 17.2 GB into 16 GB of RAM.
///
/// Falls back to the catalog default rather than to Apple's engine, which may
/// not exist on the machine. If even the default does not fit there is
/// nothing better to offer, so it is still returned.
@Test("a persisted engine this Mac cannot hold is resolved away before it is used")
func aPersistedOversizedEngineIsResolvedAway() {
    #expect(EngineEligibility.resolved(.qwen30B, physicalMemory: sixteenGB) == .qwen4B)

    // Untouched when it fits, and untouched on a machine that can hold it.
    #expect(EngineEligibility.resolved(.qwen4B, physicalMemory: sixteenGB) == .qwen4B)
    #expect(EngineEligibility.resolved(.qwen30B, physicalMemory: 64 * 1024 * 1024 * 1024) == .qwen30B)

    // Apple's engine holds no weights of ours, so memory never disqualifies
    // it — its availability is a System Settings toggle, decided elsewhere.
    #expect(EngineEligibility.resolved(.apple, physicalMemory: sixteenGB) == .apple)
}

/// **Onboarding's Continue reads this, so "ready" cannot mean "downloaded".**
///
/// Three different states all look like a model being present: weights on
/// disk, an engine that needs no weights, and an engine that reports
/// `.unavailable` because it is switched off in System Settings. Only the
/// first two can rewrite anything. Answering with `!needsDownload` alone
/// would call the third ready — `needsDownload` is false for Apple's engine
/// whatever its availability says, because it has no repository to fetch
/// from — and let a user off the model step onto a practice rewrite that
/// cannot run.
@Test("a selected engine counts as ready only if it can actually run")
@MainActor
func readinessMeansRunnableNotMerelyNotDownloading() async {
    let settings = makeSettings()
    let availability: [EngineID: EngineAvailability] = [
        .qwen4B: .needsDownload(bytes: 2_300_000_000),
        .qwen30B: .ready,
        .apple: .unavailable(reason: "Apple Intelligence is turned off."),
    ]
    let model = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0, availability: availability[$0] ?? .ready) },
        physicalMemory: sixteenGB
    )

    settings.engineID = .qwen4B
    await model.refresh()
    #expect(model.isSelectedEngineReady == false, "nothing on disk yet")

    // The trap: `needsDownload` is false here, and it is still unrunnable.
    settings.engineID = .apple
    await model.refresh()
    #expect(model.isSelectedEngineReady == false, "switched off is not ready")

    // A second model, because the positive control has to be an engine this
    // Mac can hold: 30B wants 17.2 GB and is ineligible on 16 GB however
    // installed it is, so selecting it here would have proved nothing.
    let installed = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0, availability: .ready) },
        physicalMemory: sixteenGB
    )
    settings.engineID = .qwen4B
    await installed.refresh()
    #expect(installed.isSelectedEngineReady, "positive control: installed and eligible really is ready")
}
