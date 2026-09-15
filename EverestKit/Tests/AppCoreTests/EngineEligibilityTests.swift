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
