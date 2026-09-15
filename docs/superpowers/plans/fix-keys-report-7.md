# EVE-020 — the tap failed open

**Status: fixed, both halves, with one mechanism. Overlay 75 → 76**, one dead function deleted. `AppCoreTests` 73 green, doc at 59 lines. No git command run.

Your last message said Overlay 75 / total 275; my tree agreed before I started.

---

## Commit grouping

One bug, one commit:

| Where | What |
|---|---|
| `Seams.swift` | `KeyMonitorHandle.isActive`, a live check with a defaulted init parameter |
| `CGEventTapKeyInterceptor.swift` | reports `isActive: { false }` when `tapCreate` fails, and `{ CGEvent.tapIsEnabled(tap:) }` when it succeeds |
| `FloatingPanelController.swift` | `handle` fails closed; `perform` deleted, now dead |
| `Tests/OverlayTests/` | `SpyKeyMonitor.isActive`; test `failsClosedWhenConsumptionIsUnavailable` |
| `Sources/Overlay/AGENTS.md` | the decision, plus three entries the change invalidated |

**No protocol change.** `KeyMonitorHandle`'s new parameter is defaulted and the trailing-closure call sites — including `Harness.swift`'s `KeyMonitorHandle {}` — compile untouched. `AppCoreTests` builds and runs clean. Flagging it anyway because it is a shared type: I have not gone near `PanelSurface`, and the cleanup you queued behind `fix-settings` is still queued.

---

## Verified, and worse than I had been saying

`CGEventTapKeyInterceptor.swift:80` returned `KeyMonitorHandle {}` — indistinguishable from a working one. `handle` then ran `perform` unconditionally, so the monitors executed digit, arrow, Return and Escape actions while unable to consume any of them. The auditor is right and my framing was wrong: I had been calling this "degrades to the old leaking behaviour", which undersold it. The old behaviour at least had the tap's protection absent *by design*. This is the picker behaving normally, reporting success, and editing the document underneath.

`.tapDisabledByUserInput` confirmed too — `CGEventTapKeyInterceptor.swift:53` re-enables only on timeout.

## One mechanism covers both halves

I did not add a second re-enable. `isActive` **asks the tap** (`CGEvent.tapIsEnabled`) rather than recording that creation succeeded, so:

- `tapCreate` returned nil → `isActive` is false → fail closed.
- the system switched the tap off later → `tapIsEnabled` goes false → fail closed, no notification handling needed.

`.tapDisabledByTimeout` still re-enables, and the asymmetry is deliberate rather than an oversight: a timeout is **our** slow callback and is ours to recover from — measured at 7 of 8 keys recovered. A disable the system imposed is not ours to overrule, and quietly re-enabling it would be arguing with the OS about something I cannot reproduce here. Failing closed respects it and needs no untested code path.

That also answers the half I could not have tested: I have never been able to trigger `.tapDisabledByUserInput`, so a re-enable line for it would have been production code with no test and no measurement behind it. This way there is no such line.

## Fail closed, but not all the way

Your framing — closing the picker outright is harsh, mouse-only is kinder — pushed me to look at which keys are actually dangerous unconsumed:

| Key | Leaked consequence | Verdict |
|---|---|---|
| digit | picks a style **and** replaces the selected text | refuse |
| arrow | moves the highlight **and** collapses the selection | refuse |
| Return | commits **and** submits a form in the app below | refuse |
| ⌘C | copies **and** the source app's Copy overwrites it, with `onCopy` having already dismissed the panel | refuse |
| Escape | cancels **and** reaches the app below — documented harmless, the reason Return was never bound | **allow** |

So the panel acts on Escape and nothing else. The picker stays on screen and stays mouse-clickable — the hint rows go through `pickStyle(at:)` and `copy()` directly, which never involve the frontmost app seeing a keystroke — and Escape remains the keyboard way out. That is the kinder version without leaving a panel nobody can dismiss.

**⌘C is the one I want you to look at.** Refusing it means the advertised ⌘C silently does nothing when the tap is unavailable. That is bad. Honouring it is worse: we write the rewrite, `onCopy` dismisses the panel, and the source app's own Copy lands a moment later over the top — the user believes they saved it and the only copy is gone. Refusing loses a keystroke; honouring loses the rewrite.

**A gap I am leaving, deliberately.** The ⌘C hint still renders in that state, so the panel advertises a shortcut that will not fire. Clicking the hint row *does* work, so it is not a dead control. Making the hint disappear means `keyHints` depending on interceptor liveness — a pure function of state gaining a runtime dependency, which is a bigger change than the bug warrants and would need its own round. Flagging rather than doing.

## RED and GREEN

First pass, the seam absent:
```
FloatingPanelControllerTests.swift:56:32: error: extra arguments at positions #1, #2 in call
FloatingPanelControllerTests.swift:56:33: error: missing argument for parameter 'teardown' in call
```

Second pass, seam present and the decision absent — failing on its own assertions:
```
✘ Test "with nothing able to consume, the panel acts only on Escape"
  FloatingPanelControllerTests.swift:892: Expectation failed: picked.value == nil
  FloatingPanelControllerTests.swift:894: Expectation failed: controller.highlightedStyleIndex == 0
  FloatingPanelControllerTests.swift:905: Expectation failed: copied.value == nil
✘ Test run with 76 tests in 11 suites failed after 0.089 seconds with 3 issues.
```

Three failures, one per consequence: the digit picked a style, the arrow moved the highlight, and ⌘C handed the rewrite over — all with nothing able to consume.

GREEN:
```
✔ Test run with 76 tests in 11 suites passed after 0.147 seconds.
```

Final, all targets, exit-status gated:
```
Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0
OverlayTests   ✔ 76
AppCoreTests   ✔ 73
```

**No mutation this round** — the test had an honest RED, so there was nothing to prove by breaking. (Noted your new §0 rule on one mutation at a time; it did not come up.)

The test covers install-time failure, the ⌘C case, and the tap going inactive *after* the panel is up, in three phases of one test. They are one behaviour — act only while consumption is available — and splitting them would make one regression look like three. Escape working is the positive control: it proves the monitor and handler are live, so the refusals above it are verdicts and not a dead spy.

## `perform` deleted

`handle` needed the resolved action to decide whether it was Escape, so it now does its own lookup — which left `perform` with no callers. Dead by §1, deleted. `intercept` already did its own lookup.

## Three doc entries this invalidated

Caught by re-reading rather than by a test, which is the usual way stale docs surface:

- The blockquote still told the shell that a revoked grant means "the keys leak again, exactly as before". It does not any more; it fails closed. The capture-before-picker advice stays, now justified as defence in depth rather than as the fallback.
- "widening the tap past `stylePicker`" — stale since the tap legitimately covers three more states. Now "past the states in the table".
- "dropping `makeKey()` from `present`" was listed as a hazard, and is now the opposite of what we want. Replaced with "letting the monitors act on a key the tap is not there to take".

## Manual list

**Check 13 changes meaning.** It currently says that if `tapCreate` returns nil the picker "silently degrades to the old leaking behaviour". That is the bug this fixes. It should now read: revoke Accessibility, open the picker, press `3` — expect **nothing at all** to happen, and no `3` in the document. Escape must still close it.

**Check 12's replacement** — the note that a revoked grant stops ⌘C being consumed — needs the same correction: ⌘C is now refused rather than honoured-then-overwritten, so the observable is "⌘C does nothing", not "the clipboard gets the wrong thing".

Checks 11 and 23 unaffected.
