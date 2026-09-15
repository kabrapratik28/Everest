> **Superseded fact:** this report repeats the claim that web and Electron password fields
> do not set `IsSecureEventInputEnabled()`. Measured false on 2026-09-15 — Chrome 153 sets it,
> and Blink refuses the copy outright. That claim produced a P0 (EVE-030) that did not exist.
> Kept as a record of what was believed at the time.

# Round 2 — test-quality audit

Read-only. No file in `EverestKit/` was written. Every mutation below ran
against a copy at `/tmp/everest-mut`, per root §0, and the copy has been
deleted.

**What was audited.** All 49 files under `EverestKit/Tests/`, against the
sources they drive. Baseline at the start: 251 tests green (RewriteCore 19,
Engines 32, AppCore 58, Overlay 68, TextBridge 74).

**The tree moved under me, twice.** `fix-keys` and `fix-model`/`fix-settings`
landed `pickerIsSpent`, the sixteen-hex-digit `openTag`, and three new tests
while this ran, which contaminated one mutation batch — I re-snapshotted and
re-ran it. At the end: 254 tests, and `OverlayTests` is RED on one test,
`"an empty picker ends on a key it cannot answer instead of swallowing it
forever"`. That is an agent mid-RED, not a finding; every mutation result
below is stated as *additional* failures beyond it. Line numbers are against
the working tree as of `4a72115` + uncommitted changes.

Nothing here re-reports `PUNCH-LIST.md`, the round-1 fixes, or anything
`MANUAL-CHECKS.md` correctly owns.

---

## 1. The rung-8 secure-field re-check has no test — traced

`Sources/TextBridge/SelectionCoordinator.swift:138` — `try refuseIfSecure(revealed)`

**Mutation:** delete that line. **All 74 TextBridge tests pass.**

This is root §6 row 1, on the branch where it is the *only* copy of the guard:

- Rung 0 (`IsSecureEventInputEnabled`) does not fire — `TextBridge/AGENTS.md`
  records as measured that web and Electron password fields do not set it.
- The rung-4 subrole check at line 94 cannot fire either, because it is
  guarded by `if let focused` and `focused` was `nil`. That is *why* rung 8
  ran.
- So on the Chromium/Electron path, line 138 is the whole of the defence, and
  deleting it costs nothing in the suite.

**What no test would catch:** deleting line 138 and reading a password out of
an Electron app whose accessibility tree was off until we asked.

`CaptureChainTests.manualAccessibilityEnablesTheTreeAndRetriesOnce:167` builds
exactly this fixture and never sets a subrole. The missing test is three lines
in the fake that is already there:

```swift
ax.onEnableManualAccessibility = { [weak ax] in
    ax?.focused = testElement()
    ax?.subrole = "AXSecureTextField"
    ax?.selected = "hunter2"
}
#expect(throws: CaptureError.secureField) { _ = try coordinator(ax).capture() }
#expect(ax.textReads == 0)          // positive control: enables == 1
```

Highest-severity finding here: it is the guard the project names first, and it
is unprotected on the branch it exists for.

## 2. The 8,000-character refusal is pinned to one rung, not to the choke point — traced

`Sources/TextBridge/SelectionCoordinator.swift:62-63`

**Mutation:** move the check out of `capture()` and into the rung-5 branch
only. **All 74 TextBridge tests pass.**

Both tests that exercise it — `CaptureRefusalTests.refusesInputOverTheCharacterLimit:146`
and `acceptsInputExactlyAtTheLimit:166` — drive rung 5 through `ax.selected`.
Nothing drives an over-limit capture through rung 7 (`AXStringForRange`) or
rung 9 (⌘C). The comment on line 59 says *"One choke point, so a future rung
cannot forget it"*; the suite pins the limit's existence, not its placement.

**What no test would catch:** the limit ceasing to apply to the clipboard
route — which is every context in root §3's copy-only column: Terminal,
Ghostty, PDFs, ordinary web prose, Google Docs. The user then gets
`GenerationError.truncated` from the decoder instead of `CaptureError.tooLong`
from the capture, after a full prompt encode. (`EngineLimits.outputBudget`
floors its headroom at 64, so there is no negative-budget crash — I checked.
The loss is the honest, early refusal the limit exists to give.)

Cheapest fix: `TextFidelityTests` already parameterises over `Route.allCases`;
the over-limit case wants the same shape, one `@Test(arguments: Route.allCases)`.

## 3. `pending` is never proved to be cleared — traced

`Sources/AppCore/RewriteCoordinator.swift:95` and `:122`

**Mutation:** delete *both* `pending = nil` lines. **All 59 AppCore tests pass.**

Two things go unprotected, and the first is a wrong-target write:

- **`supersede():122`.** `chooseStyle()` parks a snapshot in `pending`. A
  second hotkey press supersedes. A `pickStyle` arriving after that reads the
  *stale* snapshot, and `pickStyle:93` has no generation guard — it stamps
  `run` with the *current* generation, so every `mine == generation` check
  passes and the rewrite reaches `apply`. `pending = nil` is the only thing
  stopping it. This is the neighbour of `ROUND-2-PLAN.md`'s carried-in
  `chooseStyle:74` finding, and unlike that one it needs no exotic schedule:
  `chooseStyle()`, `quickImprove()`, `pickStyle(p)` in sequence is enough.
- **`pickStyle():95`.** Root §6's *"Only the current transaction's original in
  memory"* — a captured private selection stays resident after its transaction
  ends.

The test is three `await`s and one assertion; `CaptureSource` and
`ApplyRecorder` already exist for it.

## 4. `rangeDerivedRefusalPrecedesValidation` has no positive control — traced

`Tests/TextBridgeTests/ReplacementTests.swift:367-379`

Two negative assertions (`ax.focusResolutions == 0`, `ax.textReads == 0`) and
nothing positive — §1's rule, in its plainest form.

**Mutation:** replace the range-derived `handOff` with a bare `return .replaced`
— the rewrite is silently dropped, nothing is written, nothing reaches the
clipboard, and the user is told it worked. **This test passes.** Its sibling
`rangeDerivedSnapshotForcesCopyOnly:340` is what fails.

**What it would not catch:** anything that makes `apply` return before touching
the accessibility API, including the silent-success case above.

Fix is one line (`#expect(outcome == .copiedOnly(cause: .rangeDerived, …))`),
but the §1-preferred answer is to fold it into the sibling: the two share a
fixture and only the ordering claim is unique, so one test with three
assertions replaces two tests that fail together.

## 5. `cancellingADownloadStopsItAndLeavesThePanelDown` is conditionally vacuous — traced

`Tests/AppCoreTests/RewriteCoordinatorTests.swift:641-642`

```swift
let afterHide = Array(log.entries.drop(while: { $0 != "hide" }).dropFirst())
#expect(afterHide.contains { $0.hasPrefix("present") } == false, …)
```

When `"hide"` is absent from the log, `drop(while:)` drops everything,
`afterHide` is empty, and the assertion holds trivially.

**Mutation:** remove `panel.dismiss()` from `RewriteCoordinator.cancel():89`.
**Only `cancellingStopsTheGenerationAndDismissesThePanel` fails** — this test
passes, despite "leaves the panel down" being half its name.

Honest scope: the guard this test is actually for *is* protected. I mutated the
generation check out of `prepare()` and this test caught it. So it is a latent
vacuity, not a live one — the panel-down half is carried by a different test.
One line closes it: `#expect(log.entries.contains("hide"))` before line 641.

## 6. `show()`'s coalescer and clock resets are untested — traced

`Sources/Overlay/FloatingPanelController.swift:60` and `:65`

**Mutation:** remove either, or both. **No additional Overlay failures.**

They are mutually redundant, which is why neither dies alone: with the
coalescer reset, a stale flush returns `nil`; with the clock cancelled, no
flush fires. Removing both is the reachable bug, and nothing notices.

Reachable path: supersession calls `panel.show(.preparing(nil))` *without*
`dismiss()` (`RewriteCoordinator.run():132`). A snapshot held by transaction 1
with its flush timer already scheduled then renders transaction 1's streamed
text over transaction 2's panel. Visual only, no data loss — but it is an
abandoned generation reaching the screen underneath the coordinator's
generation checks, which is the class those checks exist for.

## 7. `announcedKind = nil` in `show()` is untested — traced

`Sources/Overlay/FloatingPanelController.swift:63`

**Mutation:** remove it. **No additional Overlay failures.**

Same supersession path: `show()` with no `dismiss()` in between leaves
`announcedKind` at the previous transaction's kind, so the new transaction's
first state is never announced. Low severity and accessibility-only — but this
is not the untestable half of VoiceOver that root §0 exempts. Whether
`announce` is *called* is above the seam and `SpySurface.announced` already
records it.

---

## Tests to delete (§1)

**D1 — `ReplacementTests.successfulWriteDoesNotChainIntoAPaste:193-205`.**
Its two assertions (`ax.writes.count == 1`, `keystroke.pastes == 0`) are a
strict subset of `matchingTargetIsReplacedInPlace:166`'s
(`ax.writes == ["the rewrite"]`, `keystroke.pastes == 0`), over an identical
fixture. No production change can fail one without failing the other. Move its
doc comment — the false-negative asymmetry argument, which is the thing warning
the next person off adding a confirming read — onto the survivor, then delete.

**D2 — `Tests/EnginesTests/EngineConformanceTests.swift` (whole file).**
Mutation-confirmed: breaking `AppleFoundationEngine.id` fails this *and*
`AppCoreTests.everyCatalogEntryBuildsItsOwnEngine` — one root cause, two
failures. What is left after that is a compile-time conformance claim already
forced by `EngineFactory.live(for:) -> any RewriteEngine`, plus an `id` getter
on `MLXEngine` that returns its own init argument.

One thing is genuinely lost: it is the only conformance check *inside* the
Engines target. If that is wanted, keep it — but then rewrite the comment,
which currently claims a runtime assertion "so the test is not vacuous" that
another target already makes.

**D3 — `LoadOnceTests.existingIsNilBeforeAnyLoad:103-106`** (marginal).
`#expect(await LoadOnce<Int>().existing == nil)` on a freshly constructed
value. No plausible implementation fails it, and the case with teeth —
`existing == nil` after a load *threw* — is already asserted inside
`aFailedLoadIsRetried:89`. §1's "don't test a plain getter". One line either way.

## One stale comment inside a test

`Tests/AppCoreTests/RewriteCoordinatorTests.swift:143-145`:

> Note `""` and not whitespace: `clean` trims only inside the envelope, so
> `"   "` is a non-empty rewrite as far as `validate` is concerned and would be
> written.

False. `OutputValidator.validate` guards
`cleaned.contains(where: { !$0.isWhitespace })`, and
`CoreTests.outputValidatorValidateRejectsWhitespaceOnlyOutput` pins exactly the
opposite. The comment predates the blank check moving into `validate`. It is
worth fixing rather than leaving because of what it says: that whitespace-only
output reaches the user's document. That is an invitation to "fix" a guard that
is already correct.

---

## Checked and sound

Recorded so nobody re-derives it.

**The `SpyKeyMonitor` trap does not generalise.** No other target has a double
with a `handler?(…) ?? false` shape or any teardown that can silently disarm a
spy. TextBridge's fakes (`FakeAccessibility`, `FakeKeystroke`,
`FakeCopyKeystroke`, `FakeClipboardCapture`, `FakeSystem`) are stored-property
fakes with counters and no lifecycle. Engines' `ScriptedTokenProducer`,
`ScriptedFetcher`, `CountingAppleSystemModel` likewise. AppCore's
`StubKeyMonitor` returns a no-op handle and is never sent a keystroke, which
`Harness.swift:62-70` states on purpose.

**Every other negative assertion against a double has a positive control in the
same test.** I checked all of them; the ones worth naming because the control is
non-obvious: `refusesWhenAnotherProcessIsFrontmost` (the pasteboard holds the
rewrite), `zeroLengthRangeStopsTheChain` (`throws: .noSelection`),
`declinesBeforePostingWhenTheClipboardCannotBeBorrowed` (`== .unavailable`),
`aCaptureCannotBorrowDuringAReplacement` (`captured.value == .unavailable`),
`readinessMarkerIsHonouredOnlyWhileWeightsExist` (`producer.loadedFrom`),
`pinnedRevisionIsRequiredAndIsTheOneFetched` (a second fetcher that *was*
asked), `theStoredPreferenceIsAppliedAtLaunch` (`start()` then `[.regular]`).
Finding 4 is the only exception I found.

**§6 guards killed by mutation:** the `prepare` generation check, `cancel()`'s
dismiss, the range-derived hand-off, `pickerIsSpent`'s reset in `show()`,
`followsTail`'s reset in `show()`. **Traced by reading only, not mutated** —
each has a test asserting directly on the guard's effect, so I did not spend a
build on them: the rung-4 subrole refusal, the prompt-injection frame, output
validation before replacement, `changeCount`-gated restore, the oversize
clipboard refusal, `CFEqual` revalidation, never-trim, the picker tap's
arming/teardown.

**Not redundant, though they look it.** `OutputCompletenessTests`,
`AppleFoundationEngineTests.truncatedOutputIsRefused` and
`MLXEngineTests.truncatedOutputIsRefusedEvenWhenTheStopReasonSaysOtherwise` all
die if `looksTruncated` breaks, but each also dies alone if its own engine
stops consulting the rule — three root causes, not one.
`ReplacementTests.refusesWhenTheRangeHasMoved` / `refusesWhenTheTextHasChanged`
assert the same outcome from two different validator conditions.
`heldForManualCopyWhenNeitherRouteIsSafe` / `pasteRouteHeldWhenTheClipboardCannotBeBorrowed`
reach the same state through the validator-failed hand-off and the paste
route's front check respectively.

**Marginal, left alone.** `streamingUpdatesAreCoalesced` and
`updateFromEventUsesTheSamePath` differ by one line of delegation in
`update(from:)`; the second is defensible as the guard against a second
unthrottled path. `PanelStateTests`' per-state loops each end with two or three
assertions that restate a case the loop already covered — duplication inside
one test, no signal cost, and it reads as deliberate emphasis.

## Mutation log

Every one ran in `/tmp/everest-mut`, as `swift build --build-tests && xcrun
xctest .build/out/Products/Debug/<T>Tests.xctest` on the whole bundle.

| # | Mutation | Result |
|---|---|---|
| 1 | drop `pending = nil` from `supersede()` | AppCore 58/58 pass → **hole** |
| 2 | drop both `pending = nil` sites | AppCore 58/58 pass → **hole** |
| 3 | `cancel()` no longer dismisses | 1 fail: `cancellingStopsTheGenerationAndDismissesThePanel`; the download test **passes** |
| 4 | `prepare()` drops its generation check | 1 fail: the download test → guard **covered** |
| 5 | length check moved from `capture()` into rung 5 | TextBridge 74/74 pass → **hole** |
| 6 | `show()` drops `coalescer = StreamCoalescer()` | no additional fail → **hole** |
| 7 | `show()` drops `clock.cancel()` | no additional fail → **hole** |
| 8 | `show()` drops `announcedKind = nil` | no additional fail → **hole** |
| 9 | `show()` drops `pickerIsSpent = false` | `pickerKeysAreConsumed` fails → **covered** |
| 10 | `show()` drops `followsTail = true` | `tailFollowingYieldsToTheUser` fails → **covered** |
| 11 | `show()` drops both 6 and 7 | no additional fail → **hole** |
| 12 | rung-8 `refuseIfSecure(revealed)` deleted | TextBridge 74/74 pass → **hole** |
| 13 | `AppleFoundationEngine.id` → `.qwen4B` | fails in both Engines *and* AppCore → **redundant pair** |
| 14 | range-derived branch → bare `return .replaced` | `rangeDerivedSnapshotForcesCopyOnly` fails; `rangeDerivedRefusalPrecedesValidation` **passes** |
