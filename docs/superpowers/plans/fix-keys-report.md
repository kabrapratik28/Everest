# Picker key passthrough — fix report

**Status: done.** 61 → **65 tests**, all passing. Root cause confirmed, including the part you asked me to check rather than assume.

Scope held: `Sources/Overlay/` + `Tests/OverlayTests/` only. Nothing in `Settings/`, `TextBridge/`, `Engines/`.

---

## 1. Root cause — confirmed, and measured rather than reasoned about

Your diagnosis was right on every point. Two independent reasons the picker's keys reach the frontmost app:

1. `NSEventKeyMonitor.swift:18-23` installs `addGlobalMonitorForEvents`, whose handler returns `Void`. The code already discards the verdict: `_ = handler(keystroke)`. An observer cannot consume.
2. Even the *local* monitor could not have helped: `handle` returned `state.acceptsKeyWindow`, which is `false` for `stylePicker`.

### The digit case does happen

You asked me to confirm it. I built a probe that mirrors Everest — an `.accessory` `NSApplication` that never activates and never has a key window — and drove a scratch TextEdit document from `System Events` (a separate process, like real hardware). TextEdit was frontmost throughout, checked at the moment of typing.

**Control, i.e. today's behaviour.** Document starts as `ORIGINAL`, ⌘A selects it, then `3`, then `4`:

```
frontmost app while typing: com.apple.TextEdit
>>> TextEdit document now reads: 34
```

The selection was destroyed and replaced by the picker's own keystrokes. That is the data loss.

**The arrow half of the user's report.** `ORIGINAL`, ⌘A, one Down arrow, then `X`:

```
>>> after select-all, Down, then X the document reads: It ORIGINALX
    ('X' alone = selection survived;  'ORIGINALX' = the arrow collapsed it)
```

`ORIGINALX` — the arrow collapsed the selection to a caret. (`It ` is stray keyboard noise from elsewhere on the machine during the run; it does not affect the reading.)

## 2. The event tap works, and does not cost frontmost

Same probe, same run, with a `.cgSessionEventTap` / `.defaultTap` installed in the non-activating process, consuming **only** a bare `3`:

```
frontmost app while typing: com.apple.TextEdit
>>> TextEdit document now reads: 4
tap saw keyDowns: ["a/kc0", "3/kc85", "4/kc86"]  consumed: ["3/kc85"]
```

`3` never reached TextEdit; `4` passed through untouched; TextEdit stayed frontmost. So the picker can swallow its own keys with `acceptsKeyWindow` left `false` — no change to the key-window rules, no `copiedOnly` downgrade.

**No double-fire.** I ran the tap *and* a global `NSEvent` monitor together, which is what the picker now has:

```
tap saw:      [... "3", "4" ...]
tap consumed: ["3"]
global NSEvent monitor saw: [... "4" ...]     <- no "3"
```

A key the tap deletes does not reach our own monitor either, so a consumed key is acted on exactly once.

**Incidental finding worth keeping.** `System Events` synthesises digits as *keypad* keycodes (85, 86), not 20/21. The tap therefore reduces `CGEvent → NSEvent(cgEvent:) → Keystroke(_:)` and reuses the existing adapter, so there is one parsing path rather than a second one that could drift.

### `.tapDisabledByTimeout` is real and is handled

Forced a timeout by stalling the callback 3 s, then sent 8 keys:

```
ARM A: ignore the timeout     RESULT presses=8 seenByTap=1 timeoutNotices=2
ARM B: re-enable on timeout   RESULT presses=8 seenByTap=7 timeoutNotices=1
```

Ignoring it means the picker stops answering the keyboard for the rest of the session, silently. `CGEventTapKeyInterceptor` re-enables.

---

## 3. Behaviours driven out, with RED and GREEN

Baseline before any change: `✔ Test run with 61 tests in 10 suites passed`.

### (1) The tap is armed only while the picker is on screen

RED, first pass — the seam does not exist:
```
FloatingPanelControllerTests.swift:105:25: error: extra argument 'keyInterceptor' in call
```
RED, second pass — seam present, decision absent, so it fails on its own assertion:
```
✘ Test "the event tap is armed only while the picker is on screen" recorded an issue at
  FloatingPanelControllerTests.swift:553:9: Expectation failed: tap.installs == 1
✘ Test run with 62 tests in 10 suites failed after 0.081 seconds with 1 issue.
```
GREEN:
```
✔ Test "the event tap is armed only while the picker is on screen" passed after 0.001 seconds.
✔ Test run with 62 tests in 10 suites passed after 0.054 seconds.
```

### (2) The picker's keys are consumed

RED:
```
✘ ... Expectation failed: tap.send(PanelKeyMapTests.arrowDown) == true
✘ ... Expectation failed: tap.send(PanelKeyMapTests.arrowUp) == true
✘ ... Expectation failed: tap.send(PanelKeyMapTests.enter) == true
✘ ... Expectation failed: tap.send(PanelKeyMapTests.escape) == true
✘ ... Expectation failed: tap.send(PanelKeyMapTests.digit(3)) == true
✘ Test run with 63 tests in 10 suites failed after 0.052 seconds with 5 issues.
```
GREEN:
```
✔ Test "the picker's keys are consumed, so the app underneath never sees them" passed after 0.001 seconds.
✔ Test run with 63 tests in 10 suites passed after 0.112 seconds.
```

### (3) A key the picker does not use passes through untouched

**Disclosed: no honest failing ordering.** The broken baseline also returned `false` for these keys, so this guard could never have been RED first. Proved by mutation **on a copy at `/tmp/emut`** (`intercept` changed to swallow everything while the picker is up); the shared tree was never mutated:

```
✘ ... Expectation failed: tap.send(bareZ) == false
✘ ... Expectation failed: tap.send(PanelKeyMapTests.digit(3, plain: false)) == false
✘ ... Expectation failed: tap.send(Keystroke(keyCode: 0, characters: "3", modifiers: .shift)) == false
✘ ... Expectation failed: tap.send(PanelKeyMapTests.commandC) == false
✘ ... Expectation failed: tap.send(PanelKeyMapTests.digit(9)) == false
✘ Test run with 64 tests in 10 suites failed after 0.208 seconds with 5 issues.
```
Unmutated: `✔ Test run with 64 tests in 10 suites passed after 0.067 seconds.`

### (4) Releasing the controller with the picker up removes the tap

Also no honest failing ordering. The existing monitor test does not cover this — it never opens the picker, so it never installs a tap. Mutation on the copy, `[weak self]` dropped from the interceptor handler (retain cycle: handler → controller → handle → handler):

```
✘ ... Expectation failed: tap.removals == 1
✘ ... Expectation failed: tap.isInstalled == false
✘ Test run with 65 tests in 10 suites failed after 0.039 seconds with 2 issues.
```
Unmutated: `✔ ... passed after 0.001 seconds.` / `✔ Test run with 65 tests ... passed`

### (5) Bug 2 — a number key picks its row, for every row that carries a number

The gap is real and is what you suspected. `AppSettings.styles` is a user-editable, uncapped `[Preset]` (`Settings.swift:20`) shown directly by `RewriteCoordinator.swift:74`; five is only the shipped default. `numberedRows = 5` meant every style anyone added had **no digit drawn against it at all** (`StylePickerView` renders `nil` past the limit) and was reachable by arrow only.

RED:
```
✘ Test "a number key picks its row, for every row that carries a number" recorded an issue at
  PanelKeyMapTests.swift:47:13: Expectation failed:
  PanelKeyMap.action(for: Self.digit(number), in: picker) == .pickStyle(index: number - 1)
  [x4 — digits 6, 7, 8, 9]
✘ Test run with 65 tests in 10 suites failed after 0.065 seconds with 4 issues.
```
GREEN:
```
✔ Test "a number key picks its row, for every row that carries a number" passed after 0.001 seconds.
✔ Test run with 65 tests in 10 suites passed after 0.071 seconds.
```

Kept small, as asked: `numberedRows` 5 → 9. No input buffer, no multi-digit entry, no commit key. Nine is where a single keystroke runs out — `0` is not a row, and a tenth needs two digits, which is a jump-to-line dialog, not a picker. A tenth style keeps the arrows and gets no number rather than a wrong one. I extended the existing behaviour's test rather than adding a parallel one (§1: one test per behaviour), and moved the boundary test to the new edge.

### Final

```
✔ Test run with 65 tests in 10 suites passed after 0.056 seconds.
```

---

## 4. What changed

| File | Change |
|---|---|
| `Sources/Overlay/CGEventTapKeyInterceptor.swift` | **new.** The `KeyMonitoring` that consumes. Below the seam, hand-checked, like `NSEventKeyMonitor`. |
| `Sources/Overlay/FloatingPanelController.swift` | `keyInterceptor` dependency; `state.didSet` → `syncKeyInterceptor()`; `handle`/`intercept` split over a shared `perform`. |
| `Sources/Overlay/FloatingPanelController+Live.swift` | `live()` supplies `CGEventTapKeyInterceptor()`. |
| `Sources/Overlay/PanelKeyMap.swift` | `numberedRows` 5 → 9, with the reasoning. |
| `Sources/Overlay/StylePickerView.swift` | Comment only — it already follows `numberedRows`. |
| `Sources/Overlay/AGENTS.md` | Consume-vs-observe recorded as the headline decision. **59 lines**, inside the 60 budget. |
| `Tests/OverlayTests/…` | 4 new controller tests, 1 behaviour extended, 1 boundary moved. |

Design notes worth flagging:

- **The tap reuses `KeyMonitoring` rather than adding a protocol.** Same shape, same `KeyMonitorHandle`, same "returns whether it consumed" contract. `KeyMonitoring` now has two production adapters, which is recorded in `AGENTS.md`.
- **Lifetime is structural, not disciplinary.** `state` is a `didSet` property, so no path can enter or leave the picker without the tap following. `disarmKeyMonitor()` clears both handles, so `dismiss()` stays the single exit. Controller deallocation drops both.
- **`handle` vs `intercept`.** The monitors still may not claim an event they did not earn with key status (`acted && acceptsKeyWindow`); the tap claims exactly what it acted on (`acted`). The existing tests that pin the monitor contract — `escapeCancelsWithoutConsumingWhenNotKey`, `commandCCopiesAndIsConsumedOnlyInATerminalState` — still pass unchanged.
- **One line of adapter code no test drives**, disclosed: the tap callback binds `let handler = context.handler` before invoking. A handler that synchronously moved the panel off the picker would release the tap, and therefore the closure, while it was still running. Not reachable today (`RewriteCoordinator.pickStyle` is `async`), but the adapter runs a shell-supplied closure and I would rather not depend on that. It is a lifetime correctness line below the seam, not behaviour.

---

## 5. Things I could not verify without a running app, and one thing to decide

**Not verifiable here (stated plainly rather than claimed):**

- That Everest's *own signed binary* can create the tap. I proved Accessibility is sufficient and that `tapCreate(.cgSessionEventTap, .defaultTap)` succeeds under it, but permission is keyed to the code signature (root `AGENTS.md` §7), so the .app needs one manual check after signing. If permission is revoked, `tapCreate` returns nil and `install` returns an empty handle — the picker still works through the monitors and leaks keys exactly as it did before, which is why I left the "capture the selection before showing the picker" note in `AGENTS.md` rather than deleting it as now-redundant.
- End-to-end in a real rewrite: ⌘⇧I in Sublime, arrow down, digit, selection intact, replacement in place. My evidence is at the mechanism level with TextEdit as the source app, not through Everest itself.

**Two things for you, neither blocking:**

1. **Root `AGENTS.md` §7 is now stale** and I did not edit it, being out of scope. The line *"A global monitor observes keys, it doesn't consume them. Pressing `3` in the picker selects style 3 and types `3` into the frontmost app"* is no longer true of the picker. The advice that follows it — capture before showing — is still correct and should stay; only the justification needs rewording. §6's guard table could also use a row for the tap's lifetime.
2. **`AppCoreTests` has one failure that is not mine**: `"every capture refusal explains its own remedy"` — `Expectation failed: messages[4].contains("com.1password.1password")`, about refusal wording. Nothing in this change touches capture or refusals. Flagging it so it is not read as fallout from the new constructor parameter.

**Two notes on the shared tree:** `Tests/AppCoreTests/Harness.swift` already carried `keyInterceptor: StubKeyMonitor()` when I checked — another agent patched it while I was working, so I never edited outside my scope. And all mutation work ran against a copy at `/tmp/emut`, now deleted along with the probes; the shared tree was only ever read from.
