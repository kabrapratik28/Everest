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

/// Selection and installation are different facts, and the row has to carry
/// both or a view is left inferring one from the other.
///
/// `engineID` defaults to `.qwen4B`, so on a brand-new Mac the selected model
/// is *always* the uninstalled one. Onboarding read selection as the whole
/// story: the default row said "In use", was disabled, and never mentioned the
/// 2.3 GB that had not arrived yet. There was no way forward from the model
/// step — the first-run screen whose entire job is getting a model onto disk.
@Test("a row carries its install state as well as its selection, so the model in use can still be downloaded")
@MainActor
func aRowKnowsWhetherItIsInstalled() async {
    let settings = makeSettings()
    settings.engineID = .qwen4B
    let availability: [EngineID: EngineAvailability] = [
        .qwen4B: .needsDownload(bytes: 2_300_000_000),
        .qwen30B: .ready,
        .apple: .unavailable(reason: "Apple Intelligence is turned off."),
    ]
    let model = ModelSettingsModel(
        settings: settings,
        engineFor: { StubEngine(id: $0, availability: availability[$0] ?? .ready) }
    )
    await model.refresh()
    let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })

    // The whole bug: in use *and* not yet on disk.
    #expect(rows[.qwen4B]!.isSelected)
    #expect(rows[.qwen4B]!.needsDownload)
    #expect(rows[.qwen30B]!.needsDownload == false)

    // Apple's engine has no repository, so a download button could do nothing
    // whatever its availability says.
    #expect(rows[.apple]!.needsDownload == false)

    // And the row says so in words, because a disabled button with no
    // explanation is the same dead end with a different shape.
    #expect(rows[.qwen30B]!.installSummary == "Installed")
    #expect(rows[.qwen4B]!.installSummary.localizedCaseInsensitiveContains("download"))
    #expect(rows[.apple]!.installSummary == "Apple Intelligence is turned off.")
}

/// The 17.2 GB option is offered on Macs that cannot hold it.
///
/// `ModelCatalog` lists it unconditionally. On a 16 GB Mac the weights alone
/// exceed physical memory before any KV cache, so the honest outcome is
/// severe swapping or a failed load — after a 17.2 GB download. Catching that
/// afterwards is too late; the download is the expensive part.
///
/// Shown with the reason rather than hidden. A row that silently disappears
/// leaves a user who read about the model hunting for it, and a greyed row
/// with no explanation is its own dead end. The gate takes precedence over
/// install state: a model that cannot run here must not report "Installed".
@Test("a model too large for this Mac is shown with the reason, not hidden")
@MainActor
func anOversizedModelSaysWhyItCannotRun() async {
    let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
    let model = ModelSettingsModel(
        settings: makeSettings(),
        engineFor: { StubEngine(id: $0) },
        physicalMemory: sixteenGB
    )
    await model.refresh()
    let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })

    #expect(rows[.qwen4B]!.fitsInMemory)
    #expect(rows[.qwen30B]!.fitsInMemory == false)
    // Still listed, and saying why. `StubEngine` reports `.ready`, so without
    // the gate taking precedence this row would read "Installed".
    #expect(rows[.qwen30B]!.installSummary.localizedCaseInsensitiveContains("memory"))
    #expect(rows[.qwen30B]!.installSummary != "Installed")

    // A Mac that can hold it is not gated.
    let roomy = ModelSettingsModel(
        settings: makeSettings(),
        engineFor: { StubEngine(id: $0) },
        physicalMemory: 64 * 1024 * 1024 * 1024
    )
    await roomy.refresh()
    #expect(roomy.rows.first { $0.id == .qwen30B }!.fitsInMemory)
}

/// A download that fails has to say so, or the user retries the same failure
/// forever with no diagnostic: the bar vanishes, the status is unchanged, and
/// nothing distinguishes "finished" from "gave up".
///
/// `download` does not throw, deliberately. Both call sites used `try?` and
/// swallowed it, and an error whose only consumer is a label is better
/// recorded than rethrown — a caller cannot then forget.
@Test("a failed download says why on the row that failed, and a retry clears the message")
@MainActor
func aFailedDownloadIsReported() async {
    let settings = makeSettings()
    let failing = StubEngine(id: .qwen4B, prepareFailure: UnexpectedFailure.somethingElse)
    let model = ModelSettingsModel(settings: settings, engineFor: { _ in failing })

    await model.download(ModelCatalog.all[0])

    #expect(model.downloadFailure[.qwen4B] == EngineFailure.reason(for: UnexpectedFailure.somethingElse))
    // Only the row that failed.
    #expect(model.downloadFailure[.qwen30B] == nil)
    // And no bar left behind suggesting it is still going.
    #expect(model.downloadProgress[.qwen4B] == nil)

    let working = ModelSettingsModel(settings: settings, engineFor: { StubEngine(id: $0) })
    await working.download(ModelCatalog.all[0])
    #expect(working.downloadFailure[.qwen4B] == nil)
}

/// The row itself is the control, so the row is what has to know it is chosen.
///
/// The tab used to draw a decorative circle and put the choosing on a separate
/// "Use" button beside it — a radio button that was a picture of one. Moving
/// the choice onto the row means the mark and the setting cannot disagree, and
/// it puts the answer in one place instead of leaving each view to recompute
/// `settings.engineID == row.spec.id` for itself.
///
/// `refresh()` rebuilds every row from the engines, so the check that the mark
/// survives that is the check that there is only one source for it.
@Test("choosing a model row is what selects it, and the mark follows the choice")
@MainActor
func choosingARowSelectsIt() async {
    let settings = makeSettings()
    settings.engineID = .qwen4B
    let model = ModelSettingsModel(settings: settings, engineFor: { StubEngine(id: $0) })

    #expect(model.rows.filter(\.isSelected).map(\.id) == [.qwen4B])

    model.select(.qwen30B)

    #expect(settings.engineID == .qwen30B)
    #expect(model.rows.filter(\.isSelected).map(\.id) == [.qwen30B])

    await model.refresh()
    #expect(model.rows.filter(\.isSelected).map(\.id) == [.qwen30B])
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

/// A test run that produces nothing has to say so, not reset to its empty
/// state.
///
/// The mirror of the coordinator's empty-stream hang, and the same silent
/// class: `runTest` clears both fields up front and then returned without
/// setting either, so the view fell through to the "The rewrite appears here."
/// placeholder. The user presses the hotkey while a test is running — the two
/// paths share one memoised engine and one `TransactionBox` — comes back to
/// Settings, and finds their test blanked with nothing said.
///
/// Clearing at the start is right; a new run must not show the old answer.
/// Ending with neither field set is what is wrong.
@Test("a test run that produces nothing says so, rather than resetting to the placeholder")
@MainActor
func anInterruptedTestReportsItself() async {
    let model = ModelSettingsModel(
        settings: makeSettings(),
        engineFor: { _ in StubEngine(events: []) }
    )

    await model.runTest(on: "a sentence")

    #expect(model.testOutput == nil)
    // Non-nil *and* non-empty: either would leave the placeholder showing.
    #expect(model.testFailure?.isEmpty == false)
}

/// The side-by-side box has to go through the same prompt the hotkey does, or
/// it is a demo of something the app does not do.
@Test("the test box rewrites its sample through the selected engine and validates the result")
@MainActor
func theTestBoxUsesTheRealPath() async {
    let settings = makeSettings()
    let engine = StubEngine(
        // An echoed envelope — the one thing `clean` still removes, since the
        // preamble strip was deleted in EVE-032. The payload only has to
        // prove the test box cleans on the same path a rewrite does.
        events: [
            .finished(
                "<selected_text_3f2a19bb7c0d4e51>A tightened sentence.</selected_text_3f2a19bb7c0d4e51>"
            )
        ]
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

/// The name is the only thing identifying a style in the picker: it is the row
/// label and the VoiceOver label, and that picker is the whole of the Choose
/// Style hotkey — named by role, because a comment cannot render from the
/// live binding the way `ShortcutCopy` makes the UI do. A style
/// named "" is a blank row the user has to pick by position and a screen reader
/// announces as nothing, and it cannot be told apart from the next blank one.
///
/// Refused for the same reason a blank instruction is, and separately from it —
/// a preset can be perfectly rewritable and still unpickable.
@Test("a preset name cannot be blanked")
func aBlankNameIsRefused() {
    #expect(PresetEdit.name(from: "   ") == nil)
    #expect(PresetEdit.name(from: "\n\t ") == nil)
    #expect(PresetEdit.name(from: "  Professional  ") == "Professional")
}

/// The subtitle is the one editable field that is allowed to be empty, and it
/// has to stay that way: `Preset(name: "New style", subtitle: "", …)` is what
/// the Add button already creates, so a rule copied over from the name would
/// make every new style's blank subtitle unclearable the moment it was typed
/// into once.
///
/// Trimmed but never refused. It is a caption under the name in the picker,
/// and an empty caption is a caption the user chose not to write.
@Test("a preset subtitle may be emptied, unlike its name")
func aBlankSubtitleIsAccepted() {
    #expect(PresetEdit.subtitle(from: "   ") == "")
    #expect(PresetEdit.subtitle(from: "  formal tone  ") == "formal tone")
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

/// The list has to be removable, because a refusal message sends the user
/// here to remove from it.
///
/// `CaptureFailure.message(for: .excludedApp)` says "Remove it from the
/// excluded apps in Settings ▸ Privacy to rewrite here" — and the only
/// affordance was `.onDelete`, which is a `List` gesture that does nothing
/// inside a macOS `Form`. `Everest/Settings/AGENTS.md` already recorded that
/// for `onMove`/`onDelete` on the Styles list; the Privacy list had the same
/// bug and the same note did not reach it. So the app instructed the user to
/// perform an action it did not implement.
///
/// By identity and case-insensitively, matching `add` and
/// `SelectionCoordinator.isExcluded`. By identity so no view holds an index
/// into an array it is mutating, and case-insensitively so an entry that was
/// refused as a duplicate of a differently-cased one can still be removed by
/// either spelling.
@Test("an excluded bundle id can be removed, matching the same way adding does")
func exclusionEntriesCanBeRemoved() {
    let existing = ["com.1password.1password", "com.example.bank"]

    #expect(ExclusionEdit.remove("com.1password.1password", from: existing) == ["com.example.bank"])
    #expect(ExclusionEdit.remove("COM.1Password.1Password", from: existing) == ["com.example.bank"])
    // Removing something absent leaves the list alone rather than trapping.
    #expect(ExclusionEdit.remove("com.nothing.here", from: existing) == existing)
}
