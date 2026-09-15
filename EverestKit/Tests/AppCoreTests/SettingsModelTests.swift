import Engines
import Foundation
import RewriteCore
import Testing

@testable import AppCore

// MARK: - The Model tab

/// A row's install state is the one thing on this tab that is not already in
/// `ModelCatalog`, and it is the thing the buttons hang off. It comes from the
/// engine's own `availability()` rather than from files being on disk, because
/// `ModelStore` only reports ready once a model has been *loaded* — a download
/// can finish and still leave weights that fail on every hotkey press.
@Test("a model row reports what the engine says about itself, not what is on disk")
@MainActor
func modelRowsTakeTheirStateFromTheEngine() async {
    let settings = makeSettings()
    let availability: [EngineID: EngineAvailability] = [
        .qwen4B: .ready,
        .qwen30B: .needsDownload(bytes: 17_200_000_000),
        .apple: .unavailable(reason: "Apple Intelligence is turned off."),
    ]
    let model = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0, availability: availability[$0] ?? .ready) }
    )

    await model.refresh()

    #expect(model.rows.map { $0.spec.id } == ModelCatalog.all.map { $0.id })
    #expect(model.rows.map { $0.availability } == ModelCatalog.all.map { availability[$0.id]! })
    // The blurb is shown inline, which is the whole reason it exists on the spec.
    #expect(model.rows.allSatisfy { !$0.spec.blurb.isEmpty })
}

/// Deleting the model you are currently using leaves the app pointing at
/// nothing: the next hotkey press silently starts a 2.3 GB download the user
/// did not ask for, having just deliberately freed that space.
///
/// Refused rather than papered over with a fallback. There is no honest model
/// to fall back *to* — the default is the one most likely being deleted, and
/// Apple's engine may not be available on the machine — so the useful answer
/// is to say which switch to make first.
@Test("the model currently in use cannot be deleted out from under the app")
@MainActor
func theSelectedModelCannotBeDeleted() async {
    let settings = makeSettings()
    settings.engineID = .qwen4B
    let model = ModelSettingsModel(settings: settings, engineFor: { StubEngine(id: $0) })

    #expect(model.canDelete(ModelCatalog.all[0]) == false)
    #expect(model.canDelete(ModelCatalog.all[1]))

    settings.engineID = .qwen30B
    #expect(model.canDelete(ModelCatalog.all[0]))
    #expect(model.canDelete(ModelCatalog.all[1]) == false)

    // Apple's engine has no repository and nothing on disk, so there is
    // nothing a delete button could do but mislead.
    #expect(model.canDelete(ModelCatalog.all[2]) == false)
}

/// The refusal has to be in the method, not only in the disabled button.
///
/// A button's `disabled` is a hint to the person clicking it; it is not a
/// guard. Anything that reaches `delete` another way — a keyboard path, a
/// later menu item, a rearranged view — would otherwise remove the weights the
/// very next hotkey press needs, and the app would silently start
/// re-downloading gigabytes the user had just freed.
@Test("deleting the model in use is refused by the method, not just by the button")
@MainActor
func deletingTheModelInUseIsRefused() async {
    let settings = makeSettings()
    settings.engineID = .qwen4B
    let model = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0) },
        storeRoot: URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    )

    await #expect(throws: ModelDeletionError.inUse) {
        try await model.delete(ModelCatalog.all[0])
    }
}

/// A test box that fails silently is worse than no test box: the user is
/// trying to find out whether the model works, and a blank result answers
/// neither way.
@Test("a model that fails in the test box says so, and shows no output")
@MainActor
func theTestBoxReportsFailure() async {
    let model = ModelSettingsModel(
        settings: makeSettings(),
        engineFor: { id in StubEngine(id: id, failure: UnexpectedFailure.somethingElse) }
    )

    await model.runTest(on: "a sentence")

    #expect(model.testOutput == nil)
    #expect(model.testFailure == EngineFailure.reason(for: UnexpectedFailure.somethingElse))
}

/// The side-by-side box has to go through the same prompt the hotkey does, or
/// it is a demo of something the app does not do.
@Test("the test box rewrites its sample through the selected engine and validates the result")
@MainActor
func theTestBoxUsesTheRealPath() async {
    let settings = makeSettings()
    let engine = StubEngine(
        events: [.finished("Sure! Here's an improved version:\n\nA tightened sentence.")]
    )
    let model = ModelSettingsModel(settings: settings, engineFor: { _ in engine })

    await model.runTest(on: "a sentence that could be tighter")

    #expect(engine.requests.map(\.text) == ["a sentence that could be tighter"])
    #expect(engine.requests.map(\.preset) == [settings.quickImprove])
    // Cleaned, exactly as a real rewrite would be before it reached a document.
    #expect(model.testOutput == "A tightened sentence.")
}

// MARK: - The Prompts tab

/// A style whose instruction is blank sends the model the safety frame and
/// nothing else, which is not a rewrite instruction — the model is left to
/// guess, and the guess lands in the user's document.
///
/// `PromptBuilder.safetyFrame` is not reachable from here at all. Only
/// `Preset.instruction` is editable, which is what keeps the injection guard
/// out of the user's hands and out of an attacker's.
@Test("a style instruction cannot be blanked")
func aBlankInstructionIsRefused() {
    #expect(PresetEdit.instruction(from: "  ") == nil)
    #expect(PresetEdit.instruction(from: "\n\t ") == nil)
    #expect(PresetEdit.instruction(from: "  Make it shorter.  ") == "Make it shorter.")
}

// MARK: - The Privacy tab

/// The excluded-app list is a security control, so its contents have to mean
/// something. An empty string matches nothing and sits in the list looking
/// like protection; a duplicate makes removal look broken, because deleting
/// one row leaves the app still excluded.
///
/// Matching in `SelectionCoordinator` is case-insensitive and exact, so a
/// duplicate differing only in case is a duplicate here too.
@Test("an excluded bundle id is trimmed, and blanks and duplicates are refused")
func exclusionEntriesAreNormalisedAndDeduplicated() {
    let existing = ["com.1password.1password"]

    #expect(ExclusionEdit.add("  com.example.bank  ", to: existing) == existing + ["com.example.bank"])
    #expect(ExclusionEdit.add("   ", to: existing) == nil)
    #expect(ExclusionEdit.add("com.1password.1password", to: existing) == nil)
    #expect(ExclusionEdit.add("COM.1Password.1Password", to: existing) == nil)
}
