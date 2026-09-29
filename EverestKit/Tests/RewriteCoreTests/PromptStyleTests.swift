import Testing
@testable import RewriteCore

/// The owner's rule for everything Everest writes: no em dashes. The frame is
/// what every prompt starts with, custom styles included, so the rule lives
/// there, and no built-in prompt may model the habit it forbids. The wording
/// itself stays unpinned (RewriteCore/AGENTS.md); this is a property of it.
@Test("the frame forbids em dashes, and no built-in prompt contains one")
func promptsForbidEmDashes() {
    #expect(PromptBuilder.safetyFrame.localizedCaseInsensitiveContains("em dash"))
    let prompts = [PromptBuilder.safetyFrame, Preset.quickImprove.instruction] + Preset.builtInStyles.map(\.instruction)
    for prompt in prompts {
        #expect(!prompt.contains("\u{2014}"), "\(prompt.prefix(40))")
    }
}

/// The prompt asks and a 4B model mostly listens: measured 0, 3 and 9 em
/// dashes per 28 rewrites across three prompt revisions on 2026-09-28.
/// "Never" needs a guarantee, so validation replaces whatever gets through.
/// Commas, because they read right between clauses and in dash pairs; code
/// spans untouched; an unspaced en dash in a range is not a dash at all.
@Test("an em dash that gets past the prompt becomes a comma, except inside code")
func emDashesThatGetThroughAreReplaced() {
    func rewrite(_ raw: String) -> String? { try? OutputValidator.validate(raw, source: "the original").get() }
    #expect(rewrite("It's clearer now—the drop is one cohort.") == "It's clearer now, the drop is one cohort.")
    #expect(rewrite("Thanks for this — I had a look.") == "Thanks for this, I had a look.")
    #expect(rewrite("The drop -- mostly one cohort -- is fixable.") == "The drop, mostly one cohort, is fixable.")
    #expect(rewrite("Thanks for this – I had a look.") == "Thanks for this, I had a look.")
    #expect(rewrite("— Pratik") == "Pratik")
    #expect(rewrite("Run `a — b` and stop — now.") == "Run `a — b` and stop, now.")
    #expect(rewrite("Pages 10–20 are fine.") == "Pages 10–20 are fine.")
}
