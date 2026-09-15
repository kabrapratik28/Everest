# EVE-010 half-open — fixed

**Status: fixed. Overlay 70 → 71, all passing. `AppCoreTests` 61 green.** No git command run.

**F3 and F5 were already done** before this arrived — `fix-keys-report-3.md`, Overlay at 70. Nothing further needed on them; this report covers only the regression.

---

## Confirmed, and it is mine

Verified both halves against the tree rather than taking the trace:

- `Everest/App/AppDelegate.swift:126` — `copyToPasteboard` calls `panel.dismiss()` **synchronously** inside `onCopy`.
- The regression is exactly where you said. The pre-`fix-keys` `handle` read `state` from the **shadowed local** bound by `guard let state`, captured before the switch:

  ```swift
  guard let state, let action = PanelKeyMap.action(for: keystroke, in: state) else { return false }
  switch action { … }
  return state.acceptsKeyWindow      // the local, captured before the action
  ```

  My split into `handle`/`perform` turned that into a read of the *property*, after `perform` had already run. `onCopy` nils it in between, so `handle` returned "not consumed" for a ⌘C it had just performed. Introduced by me in the `fix-keys` split, not pre-existing.

## Only `onCopy` is synchronous

Checked the other two rather than assuming this was the single instance:

```swift
panel.onCancel    = { [coordinator] in Task { await coordinator.cancel() } }
panel.onPickStyle = { [coordinator] preset in Task { await coordinator.pickStyle(preset) } }
panel.onCopy      = { [weak self] text in self?.copyToPasteboard(text) }   // dismisses, synchronously
```

I also swept the rest of the controller for the same shape — anywhere that reads `state` after running a handler. `copy()`, `pickStyle(at:)`, `moveHighlight`, `intercept` and `render` all read before, or read the parameter rather than the property. `handle` was the only one.

## RED

```
✘ Test "Command-C is still consumed when the copy handler dismisses the panel"
  FloatingPanelControllerTests.swift:813: Expectation failed: monitor.send(PanelKeyMapTests.commandC) == true
✘ Test run with 71 tests in 11 suites failed after 0.133 seconds with 1 issue.
```

The positive control passed in the same run — `copied.value == "the whole rewrite"` — so the `false` was a verdict about a copy that really happened, not a dead spy.

## GREEN

```
✔ Test run with 71 tests in 11 suites passed after 0.125 seconds.
```

Final across targets: `Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0`, Overlay `✔ 71`, AppCore `✔ 61`.

## The fix, in the shape you asked for

`handle` captures the state the keystroke was dispatched against, before the action runs, and reads key status from that:

```swift
let dispatchedAgainst = state
let acted = perform(keystroke)
return acted && (dispatchedAgainst?.acceptsKeyWindow ?? false)
```

It also repairs a second case nobody had reported: **Escape in a terminal state**. `run`'s `.cancel` fires `onCancel`, and had that ever dismissed synchronously the same nil-read would have said "not consumed" there too. It is async today, so this was latent rather than live — but it is fixed by the same line, because the line fixes the class rather than the instance.

## One change does not cover both this and F3 — saying so, as you asked

Same family, opposite directions, and they need different remedies:

| | `state` relative to truth | Why | Remedy |
|---|---|---|---|
| **This** | races **ahead** — `nil` before the handler returns | `onCopy` dismisses synchronously | capture the dispatched-against state |
| **F3** | lags **behind** — still `.stylePicker` after the answer | `onCancel`/`onPickStyle` are `async` | `pickerIsSpent` |

Capturing a snapshot could not have fixed F3: in F3 the dispatched-against state *is* `.stylePicker` and is entirely current. What is stale is not the state but the fact that the question has already been answered, which no snapshot of `state` records. And `pickerIsSpent` could not have fixed this one — different state, different mechanism. The shared lesson is narrower than one fix: **never decide anything about a keystroke from `state` read after the handler that keystroke invoked.** That is now a line in `AGENTS.md` and an entry in the cleanups list.

## The test lesson, which is the part I got wrong

You are right that this is the same defect as the vacuous test, arriving from outside. I checked that the surface was *told* the right thing; I did not check what production does next.

The specific failure is that `OverlayTests`' `onCopy` stub only records the text, while the app's dismisses. So the older ⌘C test — `commandCCopiesAndIsConsumedOnlyInATerminalState` — passed before and after the regression and would have gone on passing whatever the code did.

I kept both tests rather than changing the old one. They are not redundant: the old one covers *which states copy at all* (nothing in `generating`, copy in `heldForManualCopy`), the new one covers *the handler may take the panel down mid-keystroke*. Before the fix the old one passed and the new one failed, so they have different root causes.

**One observation I am not acting on.** Production has a second re-entrancy the doubles do not model: `NSPanelSurface.present` can scroll the hosting view, which fires `boundsDidChangeNotification` → `onScroll` → `controller.userScrolled(isAtBottom:)` *during* `present`. I traced it and it is harmless — `render` has already passed `followsTail` to `present` by then, so the re-entrant write only affects the next render, and the scroll it reacts to is our own programmatic scroll to the tail, which reports `isAtBottom: true`. No test, no change; recording it because it is the same shape as the bug you just found and the next person should know it was looked at rather than missed.

## Manual list, unchanged

Both round-1 items still stand: EVE-010 end-to-end through Everest itself — **now more worth running than before**, since this regression means the end-to-end check was never going to pass — and the signed binary creating the tap. This fix is fully covered by tests at the controller, but whether the unconsumed key reached the source app was never something I could observe, and you were right not to ask for it.
