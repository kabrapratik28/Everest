# `.success` at 500 ms

**Status: item 1 done. Overlay 77, doc at 59 lines.** Item 2 held, with a reason sharper than the plumbing. No git command run.

---

## 1. `.success` is now 500 ms, pinned by relations rather than by the number

You were right that the reasoning had to change with the value, and it has — in the code comment and in `AGENTS.md`. The old text argued the document is the confirmation and the panel redundant. Pratik kept the premise and overturned the conclusion: the tick is *wanted* as an acknowledgement, it just must not linger. Both files now say that.

**The test no longer asserts the number**, because the number is a taste call that has moved twice in two rounds and will move again. It asserts the two relations that carry the intent:

- **above zero** — the tick is wanted, and at zero it renders for a frame nobody sees, which is exactly the argument Pratik was answering;
- **below every other dismissing state** — it is the only one whose message the user can read off their own document, so it is the only one that should get out of the way rather than be read.

Your "success is the shortest and every other dismissing state is strictly greater" is intact and strengthened: the comparison is now against `success` itself rather than against zero, so shrinking `readOnly` towards it fails too.

RED:
```
✘ Test "heldForManualCopy never auto-dismisses; success is visible but the briefest of those that do"
  PanelStateTests.swift:72: Expectation failed: success > .zero
✘ Test run with 77 tests in 11 suites failed after 0.089 seconds with 1 issue.
```
GREEN: `✔ Test run with 77 tests in 11 suites passed after 0.076 seconds.`

`AppCoreTests:188` reads `PanelState.success.autoDismissAfter` rather than hardcoding, so it followed the change without edits, as it did last round.

## 2. Held — and the blocking question decides the words, not just the plumbing

You said to wait on the outcome plumbing. The stronger reason to wait is that **the answer to your question about a second ⌘C determines whether the copy can say "press ⌘C" at all.**

Pratik's instruction is to ask the user for ⌘C or Escape. If `fix-docs` comes back saying a second ⌘C is not safe inside the existing pasteboard transaction, then a panel whose headline is "Press ⌘C to keep your rewrite" is instructing the user to do the unsafe thing — and that is a worse failure than the wording we have, because they would be following it. So the words are downstream of that answer and I would be guessing at both.

**One finding that changes the brief slightly, and is worth telling Pratik.** The panel *already* offers both actions. `keyHints` gives `heldForManualCopy` a `⌘C Copy` row and an `esc Cancel` row — keycap badges, each one a clickable control, both derived rather than listed (⌘C wherever there is a rewrite to copy, `esc` wherever the panel will not close itself). So "name the action" is not missing; what is missing is the *headline* leading with it, the way `.readOnly` and `.targetChanged` now do. That makes item 2 a smaller change than it reads, and it means the panel is already not silent about what to do.

**And the second constraint is already met.** "Copy this before closing" does not promise the clipboard holds the rewrite — it says the opposite, that copying is still to be done. So the `.copiedOnly` wording you were worried about is not the wording this state has.

What is genuinely wrong with it: it is written for one cause and the cause now arrives in `reason`, so the title has to work for both — and it buries the action, which is the same defect Pratik reported for the copy-only states.

**Ready to go the moment you have the answer**, in either shape:
- if a second ⌘C is safe: lead with it, cause-agnostic, e.g. *"Press ⌘C to keep your rewrite"* over the `reason`;
- if it is not: the headline has to name Escape as the only action and the rewrite is lost on dismiss, which is a much worse product state and probably argues for the transaction being restructured rather than the panel being reworded.

Tell me which and it is one cycle.

## Verification

```
Overlay rc=0 · OverlayTests rc=0
OverlayTests   ✔ 77
```

**`AppCoreTests` does not build right now, and it is not mine:** `TextBridge/SelectionCoordinator.swift:204` and `:281`, *missing argument for parameter 'viaClipboard'* — `fix-docs` mid-change on exactly the auto-replace work item 2 depends on. Overlay and OverlayTests are clean.

Worth recording that my own gated command caught it and then *still* printed a green line: `swift build --target AppCoreTests` returned `rc=1`, and the `xcrun xctest` on the next line ran the previous bundle and reported `✔ 78 tests passed`. The gate told me the truth and the line underneath it did not. Same trap as §8, one layer along — the gate has to guard the *run*, not just report the build.

## Manual list

Smoke check 3 gains the observable: the panel should show the tick briefly and be gone — roughly half a second — rather than either flashing invisibly or sitting on the text. That is the thing Pratik chose between, so it is the thing to look at.
