# Overlay round 2 — F3 and F5

**Status: both fixed. Overlay 68 → 70, all passing. `AppCoreTests` 59 green.** No git command run.

Scope: `Sources/Overlay/` + `Tests/OverlayTests/` only.

---

## Commit grouping

| # | Bug | Where |
|---|---|---|
| F3 | Picker keeps answering after it has been answered, and leaks | `FloatingPanelController.swift`: `pickerIsSpent`, `endPicker()`, the rewritten `intercept`, `pickerIsSpent = true` in the `.cancel` case and in `pickStyle(at:)`, and **removal** of `armedInterceptor = nil` from `intercept` · tests: `thePickerAnswersOnce`, plus corrections to `pickerKeysAreConsumed` and `anUnclaimedKeyEndsThePicker` |
| F5 | Empty picker swallows Return and the arrows forever | `FloatingPanelController.swift`: `perform` split into lookup + `run`, `run` returning whether the action found a row, `moveHighlight`/`pickStyle` returning `Bool` · tests: `anEmptyPickerEndsRatherThanSwallow` |

`Sources/Overlay/AGENTS.md` and `PanelKeyMapTests.swift`'s `bareZ` constant carry hunks for both. Doc is **59 lines**.

**Public signature change, flagging it before you find it** (the rule from last round): `pickStyle(at:)` now returns `Bool` and is `@discardableResult`. Source-compatible — the only external caller, `NSPanelSurface.onPickStyle`, needed no change and `AppCoreTests` builds clean — but it is a public API change in a target three others depend on, so you are hearing it from me rather than from a build.

---

## Both findings confirmed against the code

**F3** — `intercept` dropped the tap at line 204 while `state` stayed `.stylePicker`. `perform` then still resolved picker keys through the global monitor, and `handle` returned `acted && acceptsKeyWindow` = `true && false`, so the key acted *and* was not consumed. Exactly the `ORIGINAL` → `34` failure, for the width of one actor hop.

**F5** — `perform` returned `true` unconditionally after its switch, but `pickStyle` is bounds-guarded and `moveHighlight` guards `!presets.isEmpty`. With no rows both are no-ops reported as successes, so "a key the picker cannot answer ends it" never fired and the tap swallowed Return and the arrows until the user found Escape.

**One thing the audit did not mention, and it matters.** The same gap exists after **Escape** and after a **successful pick** — both go async through the coordinator with `state` still `.stylePicker`. After Escape a digit started a rewrite the user had just cancelled; after a pick a second digit fired `onPickStyle` twice. The second is masked downstream by `RewriteCoordinator.pickStyle`'s `guard let snapshot = pending`, which is coupling I did not want to rely on — especially as you have that file under review for a generation-guard problem. So the fix is one rule covering all three enders, not a patch on the reported one.

### F3 RED

```
✘ Test "the picker answers once, and a key arriving before it closes is swallowed, not leaked"
  FloatingPanelControllerTests.swift:744: Expectation failed: picked.value == answer
  FloatingPanelControllerTests.swift:744: Expectation failed: picked.value == answer
  FloatingPanelControllerTests.swift:742: Expectation failed: tap.isInstalled
  FloatingPanelControllerTests.swift:743: Expectation failed: tap.send(PanelKeyMapTests.digit(3)) == true
✘ Test run with 69 tests in 11 suites failed after 0.133 seconds with 4 issues.
```

The four issues split exactly along the three enders: `enter` and `escape` each pick a second style (`picked.value == answer` twice), and `bareZ` additionally fails `tap.isInstalled` and the consume check — that pair *is* the leak.

### F3 GREEN

```
✔ Test run with 69 tests in 11 suites passed after 0.152 seconds.
```

### F5 RED

```
✘ Test "an empty picker ends on a key it cannot answer instead of swallowing it forever"
  FloatingPanelControllerTests.swift:784: Expectation failed: cancels.count == 2
✘ Test run with 70 tests in 11 suites failed after 0.194 seconds with 1 issue.
```

The keys were consumed (`tap.send(...) == true` passed — that is the positive control) and the picker never ended.

### F5 GREEN

```
✔ Test run with 70 tests in 11 suites passed after 0.191 seconds.
```

Final, with all targets rebuilt: `Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0`, Overlay `✔ 70 tests passed`, AppCore `✔ 59 tests passed`.

---

## The design decision worth arguing with

F3's fix is partly an **undo of item A**. Last round I dropped the tap synchronously so it could not outlive the user's attention. That created F3: the drop won a race it should not have entered.

The tap's life was already bounded structurally — `state.didSet` disarms on any state change, `dismiss()` disarms unconditionally. The synchronous drop bought nothing that was not already guaranteed, and cost the consumption that was the whole point of having a tap. So the gap is now made **inert** rather than **unarmed**: the tap stays and swallows, `pickerIsSpent` ensures it swallows *and does nothing*.

Item A's guarantee is intact and `anUnclaimedKeyEndsThePicker` now asserts it in the correct place — the tap survives the gap, and `controller.dismiss()` removes it.

**Empty picker, Return, and the one judgement call.** An unanswerable key that the picker *owns* is consumed rather than passed on, which differs from an unclaimed key. The reason is the guard in this directory that Return is the dangerous one to leak: a Return passed to the frontmost app submits a form or sends a message. The user pressed it at a visible Everest panel, so the panel eats it — once — and stands down. A key the picker never claims (a letter, ⌘C) is still passed through, because that one really was meant for the app underneath.

You are right that the durable fix is at the delete. A user should not be able to remove the last style, and then the empty picker never exists. My half only makes it harmless.

---

## Self-audit, two things

**I wrote one guard without a test and then removed it.** `moveHighlight` briefly got a `!pickerIsSpent` check alongside `pickStyle`'s. `pickStyle`'s is driven by `thePickerAnswersOnce`; `moveHighlight`'s was not driven by anything, and moving a highlight is not answering a question, so it did not belong to the behaviour under test. Rather than invent a test to justify code I had already written, I deleted it — `guard case .stylePicker = state` already stops it once the state moves on. Still 70 green after removal.

**Two existing tests were changed, both because the behaviour they encoded was wrong.**

- `pickerKeysAreConsumed` sent arrows, Return, Escape and a digit at *one* picker and expected the digit to still pick. That is answering a picker three times, which is precisely what F3 forbids. It now uses a fresh picker per key — the same shape `nonPickerKeysPassThroughTheTap` already needed for the same underlying reason.
- `anUnclaimedKeyEndsThePicker` asserted `tap.isInstalled == false` immediately after the key. That assertion *was* F3. It now asserts the tap survives the gap and goes on `dismiss()`.

Neither was weakened to pass; both were asserting something this round proved wrong. Worth a second look from you if you disagree, since "I changed the test" is the sentence that should always draw one.

**Root §1's new positive-control rule, applied to my own new tests.** `thePickerAnswersOnce`'s negative assertion (`picked.value == answer`) is paired with `tap.send(...) == true`, which fails if the spy is dead. `anEmptyPickerEndsRatherThanSwallow`'s `cancels.count == 2` is paired with the same. No bare negative assertions added.

---

## One process failure of mine

My build-then-test command was `swift build ... | grep -E "error|ok \(build" && xcrun xctest ...`. When `RewriteCore/OutputValidator.swift` briefly failed to compile under another agent's edit, **grep matched the word `error`, exited 0, and the `&&` ran the tests anyway** — against the stale bundle, which cheerfully reported `✔ 68 tests passed`.

That is the trap I wrote into `AGENTS.md` last round, and my own command walked into it, because I gated on grepping for the word rather than on the exit status. Every run in this report since uses:

```bash
swift build --target OverlayTests > /tmp/ov-build.log 2>&1; rc=$?
if [ $rc -ne 0 ]; then echo "BUILD FAILED (rc=$rc)"; grep -E "error:" /tmp/ov-build.log; else xcrun xctest …; fi
```

Same symptom as everything else on that list: it failed green. Worth the doc saying "gate on the exit status", not just "check the build succeeded", since I read my own sentence and still got it wrong — but that line is in my directory doc at budget, so I have left the wording to you rather than spend two lines on it.

---

## Nothing new for the manual list

Both round-1 items still stand and neither is affected by this round: EVE-010 end-to-end through Everest itself, and the signed binary creating the tap. No new manual checks — F3 and F5 are both fully reachable from tests, because the gap they concern is a state-machine gap rather than an OS behaviour.
