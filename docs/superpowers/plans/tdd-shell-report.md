# App shell — TDD report

**Status:** AppCore complete and green, 33 tests. App target written, parse-checked only.
**Command:** `cd EverestKit && swift build --target AppCoreTests && xcrun xctest .build/out/Products/Debug/AppCoreTests.xctest`

Three things need your action; they are in §6. Post-review corrections are in §9.

---

## 1. Where the code went, and why

You asked for a thin shell and warned that logic in an app target is
untestable. You added `AppCore` + `AppCoreTests`, so **every decision is in
`EverestKit/Sources/AppCore` and the app target has no branches at all.**

Three things I moved into `AppCore` that the brief put in the app target,
because each turned out to contain a branch:

- **Engine construction** → `EngineFactory.live(for:)`. Choosing between
  `MLXEngine` and `AppleFoundationEngine` is a `switch`.
- **The Italic warning** → `ShortcutNotice`. "Warn once, and only while the
  shortcut actually collides" is two conditions and a persisted flag.
- **`SystemProbing`'s production conformer** → I wrote one; it was superseded. See §5.

What is left in `Everest/App` and `Everest/Settings` is construction,
callbacks, windows and SwiftUI layout.

## 2. RED and GREEN, per behaviour

Each block is the observed output. Where the first RED was a compile failure I
say so, and §3 lists the ones I then had to prove by mutation instead.

### Capture happens before any panel

```
RED  error: cannot find 'RewriteCoordinator' in scope
GREEN ✔ Test "the selection is captured before the style picker is shown" passed after 0.001 seconds.
```

### A refused capture never reaches the picker

```
RED  ✘ recorded an issue: Expectation failed: surface.presented.map(\.kind) == [.error]
     ↳ surface.presented.map(\.kind) → [Overlay.PanelStateKind.stylePicker]
     ↳ [.error] → [Overlay.PanelStateKind.error]
     ✘ ... failed after 0.001 seconds with 2 issues.
GREEN ✔ Test "a refused capture states why and never offers a style" passed after 0.001 seconds.
```

### `.finished` is followed by validation and replacement

```
RED  error: cannot find 'Sleeping' in scope
     error: extra arguments at positions #4, #5, #6 in call
GREEN ✔ Test "finished is not the end: the cleaned output is applied, and only then reported" passed
```

Compile-only RED, so proved by mutations **M5** and **M6** below.

### An engine failure is shown, and nothing is written

```
RED  ✘ recorded an issue at RewriteCoordinatorTests.swift:115:5:
     Expectation failed: surface.presented.last?.kind == .error
     ✘ ... failed after 0.001 seconds with 1 issue.
GREEN ✔ Test "an engine failure is shown, and nothing is written" passed after 0.001 seconds.
```

### Output the validator rejects is never written

```
RED  error: value of type 'ValidationFailure' has no member 'message'
GREEN ✔ Test "output the validator rejects is refused, and never written" passed
```

Compile-only RED, so proved by mutation **M6**.

### `autoDismissAfter` is honoured, and `heldForManualCopy` is exempt

```
RED  error: cannot find type 'Sleeping' in scope
     error: extra argument 'sleeper' in call
GREEN ✔ Test "a finished rewrite closes its panel after the interval the state declares" passed
GREEN ✔ Test "a rewrite the panel is the only copy of is never closed on a timer" passed
```

There was a real intermediate RED here worth recording: implementing
auto-dismiss broke the *earlier* pipeline test, because it asserted
`log.entries.last == "present(success)"` and a `hide` now follows.

```
✘ Test "finished is not the end..." Expectation failed: log.entries.last == "present(success)"
```

That assertion was over-specified and duplicated the auto-dismiss test, so I
narrowed it to what it is actually for — `apply` precedes `present(success)` —
rather than loosening it to fit.

### Model preparation reports progress, in order

```
RED  ✘ Expectation failed: reported == [nil, 0.25, 0.5, 0.75, 1.0]
     ✘ Expectation failed: surface.presented.last?.kind == .error
     ✘ Expectation failed: engine.streamed == 0
     ✘ Expectation failed: recorder.applied.isEmpty
     ✘ Test run with 16 tests failed with 4 issues.
GREEN ✔ Test "preparing a model reports its progress, in order, before any text arrives" passed
GREEN ✔ Test "a model that fails to prepare ends the transaction" passed
```

### Cancel, exclusions, onboarding, settings, shortcut notice

```
RED  error: value of type 'RewriteCoordinator' has no member 'cancel'
RED  error: cannot convert value of type '@MainActor @Sendable ([String]) throws -> TargetSnapshot'
                        to expected argument type '@MainActor @Sendable () throws -> TargetSnapshot'
RED  error: reference to member 'tryIt' cannot be resolved without a contextual type
RED  error: cannot find 'ModelSettingsModel' in scope
     error: cannot find 'ExclusionEdit' in scope
     error: cannot find 'PresetEdit' in scope
RED  error: cannot find 'ShortcutNotice' in scope
RED  error: cannot find 'EngineFactory' in scope
RED  error: extra argument 'storeRoot' in call
     error: cannot find 'ModelDeletionError' in scope
```

One genuine behavioural RED in that group, from an assertion of mine that was
wrong rather than code that was:

```
✘ Expectation failed: root.pathComponents.suffix(3) == ["Everest", "Models", ""].filter { !$0.isEmpty }
✘ Expectation failed: root.path().contains("Application Support")
```

`URL.path()` percent-encodes the space. I fixed the test, not the path.

### Final run

```
✔ Test run with 31 tests in 0 suites passed after 0.026 seconds.
```

## 3. Where I broke the Iron Law, and what I did about it

**Four tests passed the moment I wrote them, with no behavioural RED.** Writing
the first GREEN I put in a whole `run()` skeleton — the generation counter, the
`pending` snapshot, `engineFor(settings.engineID)` — when the test in front of
me only demanded the picker. Three later tests then landed on code that already
worked. The onboarding gate was a fourth: compile-RED only.

I did not delete and restart, which §0 says I should have. I judged that
`swift build` was being broken every few minutes by concurrent edits in
`Overlay`, `TextBridge` and `Engines`, and that re-deriving the same actor
through four cycles would mostly re-test my ability to retype it. **That is my
call and you may disagree with it** — the alternative I chose was to prove each
one by mutation instead, which is the technique §0 names for guards with no
honest failing ordering.

**All mutations ran on a copy** (`/tmp/everest-mut`, cloned with its `.build`),
never in the shared tree, and the copy was deleted afterwards. Nothing was ever
mutated in place.

| # | Mutation | Caught by |
|---|---|---|
| M1 | delete every `guard mine == generation` | `a second hotkey press cancels the first generation and discards its output` |
| M2 | `pickStyle` re-captures instead of reusing `pending` | `the style picker rewrites the selection read before it appeared` |
| M4 | show the picker before capturing | `the selection is captured before the style picker is shown` (+ the refusal test) |
| M5 | write the raw output instead of the validated one | `finished is not the end…` |
| M6 | bypass `OutputValidator` entirely | `finished is not the end…` and `output the validator rejects…` |
| M7 | pin the engine to `.qwen4B` instead of reading Settings | `the engine used is the one selected in Settings at that moment` |
| M8 | remove the Accessibility gate | `onboarding stays on the permission step…` |
| M9 | sample the permission once at `init` | `onboarding stays on the permission step…` |

M2's first attempt did not compile (my mutation's syntax), so it was re-run and
is reported from the second run. M3 does not exist; I renumbered nothing else.

Verbatim, M1 and M8:

```
############ M1: delete the generation guards (supersession) ############
✘ Test "a second hotkey press cancels the first generation and discards its output"
  Expectation failed: recorder.applied == ["Second output."]
✘ Test run with 12 tests failed with 1 issue.

############ M8: remove the Accessibility gate from onboarding ############
✘ Test "onboarding stays on the permission step until it is granted, without a relaunch"
  Expectation failed: onboarding.step == .accessibility
  Expectation failed: onboarding.step == .capabilities
✘ Test run with 31 tests failed with 2 issues.

############ RESTORED ############
✔ Test run with 31 tests in 0 suites passed after 0.024 seconds.
```

## 4. The requirements you marked non-optional

| Requirement | Where | Tested |
|---|---|---|
| Actor owning one transaction; new press cancels the previous | `RewriteCoordinator`, generation counter | yes, M1 |
| Capture **before** any panel | `begin()` before `panel.show` | yes, M4 |
| `.finished` is not the end | validate → apply → terminal state | yes, M5/M6 |
| `autoDismissAfter` wired; `heldForManualCopy` never | `autoDismiss(_:generation:)` reads the state | yes, two tests |
| `TargetSnapshot` never fanned across tasks | held in `pending`, actor-private | structural |
| Default excluded-app list | `RewriteCore`, 8 entries (you extended it) | its liveness, yes |
| Template SF Symbol status item | `StatusItemController.icon()` | manual |
| `safetyFrame` never in Settings | absent from `PromptsTab`; only `instruction` is bound | structural |
| Never log selected or generated text | one `Logger`, subsystem from the bundle, no content | structural |
| Two hotkeys, warn once about Italic | `HotkeyManager` + `ShortcutNotice` | notice tested |
| Login item via `SMAppService.mainApp` | `GeneralTab` | manual |
| Settings, four tabs | `SettingsView` | rules tested in `AppCore` |
| Onboarding gates on Accessibility, then capabilities, model, real rewrite | `OnboardingModel` + `OnboardingView` | yes, M8/M9 |

Three marked "structural" are absences, not behaviours — there is no test that
can watch a field that does not exist. Each is recorded as a guard in the
relevant `AGENTS.md` so removing it is a visible change rather than a quiet
one.

## 5. `SystemProbing` had no production conformer

`TextBridge` declared `SystemProbing` and shipped only `FakeSystem` in its
tests. There was no way to construct a real `SelectionCoordinator` — the app
could not have been built while every TextBridge test passed.

`tdd-bridge` and I hit this independently and both wrote a `SystemProbe`.
**TextBridge's is the one that shipped**, correctly: the adapter belongs beside
the protocol it conforms to, and it has its own tests. Mine was deleted. Two
public types with one name, in modules the app imports together, is ambiguous
at the use site and does not compile — worth knowing as a parallel-work hazard
in its own right, because each of us was right to fill the gap and the
collision was the only thing wrong.

I see root `AGENTS.md` §0 now carries the rule that came out of this. The seam
table it asks for is in `AppCore/AGENTS.md`.

`frontmostApp()` reports `CFBundleVersion`, not the marketing version, because
`StrategyCache` invalidates on it and an app can ship a new build with the same
marketing string.

## 6. Open items

Three of the four are now closed. Recorded rather than deleted, because the
reasoning on (a) and (c) is the useful part.

**a. Resolved.** You extended the list in `RewriteCore` to eight password
managers and had the better argument for stopping there: an unverified bundle
id fails silently, so a long list buys false confidence. Your instruction to
carry the caveat into onboarding is done — see §9c.

**b. Resolved.** The app target is type-checked and compiles clean with zero
warnings in your build. It remains unreachable from `swift test`, because
`KeyboardShortcuts` is app-target-only by design, so `xcrun swiftc -parse` is
still the most this directory can verify on its own. The API surface I wrote
against was correct: `Name(_:default:)`, `onKeyDown(for:)`, `getShortcut(for:)`,
`Shortcut.key`/`.modifiers`, `Recorder(_:name:)`. Two integration fixes were
needed and were yours: `import Combine` in both views for `Timer.publish`, and
`Sendable` on `TextBridge.SystemProbe` for `OnboardingModel`'s closure capture.

**c. Resolved.** All three `project.yml` bugs fixed; it generates and builds.

**d. The one item still open.** `onKeyDown` fires while ⌘ is still held,
and capture rung 9 posts a synthetic ⌘C. Please confirm a clipboard-fallback
target (a terminal, a PDF) still captures with the chord held. If it does not,
`onKeyUp` is the fix and it is a one-word change in `HotkeyManager`.

**Not to be made speculatively.** `onKeyDown` is the more responsive of the
two and the hazard is confined to capture rung 9, which is only reached in
apps with no accessibility tree. Swapping it before the check would trade a
working behaviour for a guess.

## 7. Concerns

**`Overlay` and `TextBridge` changed under me mid-run.** `KeyMonitoring.install`
gained a `Bool` return and `ReplaceOutcome.copiedOnly` gained a
`CopyOnlyCause`. Both were improvements — the second removed a string-matching
hack I had flagged and written a contract test for, and I deleted both when the
enum landed. But my first RED was polluted by someone else's mid-edit
`Overlay` compile error, and I had to wait and re-run to get a clean one. Worth
knowing if you are scheduling more parallel work on the same package.

**I deleted `Sources/AppCore/_Placeholder.swift`**, which said to delete it
once AppCore had real source.

**The style picker's `pickStyle` has no timeout.** If the user opens the picker
and walks away, `pending` holds one `TargetSnapshot` — and therefore one
selection's text — until the next hotkey press or Escape. That is one
selection, which is what root `AGENTS.md` §6 permits ("only the current
transaction's original in memory"), so I left it. Flagging it because it is the
only place text outlives a visible transaction.

## 8. Files

Written by me:

```
EverestKit/Sources/AppCore/       AGENTS.md CLAUDE.md
                                  RewriteCoordinator.swift  PanelOutcome.swift
                                  CaptureFailure.swift      EngineFailure.swift
                                  ValidationFailure+Message.swift
                                  Sleeping.swift
                                  EngineFactory.swift       ShortcutNotice.swift
                                  OnboardingModel.swift     ModelSettingsModel.swift
                                  SettingsEdits.swift
EverestKit/Tests/AppCoreTests/    Harness.swift             RewriteCoordinatorTests.swift
                                  PanelOutcomeTests.swift   OnboardingModelTests.swift
                                  SettingsModelTests.swift  ShortcutNoticeTests.swift
                                  EngineFactoryTests.swift
Everest/App/                      AGENTS.md CLAUDE.md
                                  EverestApp.swift          AppDelegate.swift
                                  StatusItemController.swift HotkeyManager.swift
Everest/Settings/                 AGENTS.md CLAUDE.md
                                  SettingsView.swift        OnboardingView.swift
```

Deleted: `EverestKit/Sources/AppCore/_Placeholder.swift` (by me),
`EverestKit/Sources/AppCore/SystemProbe.swift` (by the lead, superseded by
`TextBridge.SystemProbe`).
Not touched: `project.yml`, `RewriteCore`, `TextBridge`, `Engines`, `Overlay`.


---

## 9. Corrections after your review

Three of your later messages found real problems. Each was driven RED first.

### a. `unverifiable` was mapped to the wrong panel state

You were right and I had it wrong. I had grouped it with `targetChanged`
because both are "we could not confirm the target". But `unverifiable` is the
permanent, *correct* state for everything captured through the clipboard —
Terminal, Ghostty, PDFs, web prose, the copy-only rows of root §3 — which are
working as designed. "The original text had moved" tells that user they did
something and implies a retry will help. It never will, and they would keep
trying.

```
RED  ✘ Test "every copy-only cause is sorted into the state that tells the user what to do"
     Expectation failed: PanelOutcome.state(for: .copiedOnly(cause: cause, reason: "why"),
                                            text: "rewritten") == .readOnly(text: "rewritten")
GREEN ✔ Test run with 31 tests in 0 suites passed after 0.035 seconds.
```

Final split: `targetChanged`, `secureField`, `pasteNotConsumed` → `targetChanged`
(the world moved and can move back, so a retry may work). `notEditable`,
`noAccessibility`, `rangeDerived`, `unverifiable` → `readOnly` (there is
nowhere to write, and a retry changes nothing).

**Where I did not take your suggestion.** You floated `secureField` → `refused`
and `noAccessibility` → `error`. I kept both in the copy-only pair, because
`copiedOnly` carries a promise — the text really is on the clipboard — and
`refused` and `error` have no `bodyText` and no "It is on the clipboard" line.
Mapping there would show the reason and silently drop the fact that the user's
rewrite was saved. Say the word if you want it the other way.

### b. `readyMarkerWithoutWeights` now reads as retryable

It was falling into the one generic sentence, which suggests switching models —
which fixes nothing — and never mentions the one useful action.

```
RED  ✘ Test "a model whose weights went missing is reported as something to retry"
     Expectation failed: missing != EngineFailure.reason(for: UnexpectedFailure.somethingElse)
     Expectation failed: missing.localizedCaseInsensitiveContains("download")
GREEN ✔ Test run with 32 tests in 0 suites passed after 0.027 seconds.
```

### c. The exclusion caveat is in onboarding, and pinned by a test

Your instruction, using my own sentence. It lives in `AppCore` as
`OnboardingModel.exclusionCaveat` rather than loose in a view, because it is a
security claim and a test can hold it to naming the browser case.

```
RED  error: type 'OnboardingModel' has no member 'exclusionCaveat'
GREEN ✔ Test run with 33 tests in 0 suites passed after 0.025 seconds.
```

### Two items needing no change

`KeyMonitorHandle` is still named that in `Overlay/Seams.swift:49`; the rename
to `TeardownHandle` has not landed, so the harness is correct as written.

`FloatingPanelController.cancel()` is the panel's *input* path and fires
`onCancel`. The coordinator calls `panel.dismiss()`; calling `cancel()` from
the `onCancel` handler would loop.

"Streaming without a prepare must fail loudly" is already covered: *a model
that fails to prepare ends the transaction* asserts `engine.streamed == 0`,
which is the same root cause, so a second test would be redundant under §1.

### One file of yours I touched

`Everest/Settings/OnboardingView.swift`, three lines, to render
`OnboardingModel.exclusionCaveat`. You claimed that directory after I had
finished it; I have not written anything else there since.
