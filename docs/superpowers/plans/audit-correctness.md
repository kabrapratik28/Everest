# Correctness and concurrency audit — read-only

Scope: `EverestKit/Sources/**`, `Everest/**`. No files changed except this one.
Each finding says whether I **traced it** (followed the concrete call path and it
happens) or **could not rule it out** (the code is wrong-shaped, the schedule or
the AppKit behaviour needed to reach it is unverified without running).

Ranked, worst first.

---

## 1. A selection over ~3,000 characters is replaced by a truncated rewrite — TRACED, text loss

- `EverestKit/Sources/TextBridge/TargetSnapshot.swift:110` — capture allows **8,000 characters**.
- `EverestKit/Sources/Engines/EngineLimits.swift:24,32-35` — output is capped at **768 tokens**.
- `EverestKit/Sources/Engines/MLXEngine.swift:115-126` — that cap goes in as `maxTokens`; whatever
  has accumulated when the decoder stops is yielded as `.finished(accumulated)`.
- `EverestKit/Sources/RewriteCore/OutputValidator.swift:41-50` — rejects output that is **empty** or
  **more than 3× the input**. There is no lower bound.
- `EverestKit/Sources/AppCore/RewriteCoordinator.swift:157-166` — validation passes, `apply` writes it.

Sequence: select ~4,000 characters of prose (one page) in any app with an editable buffer, press the
hotkey. Prompt ≈ 1,100 tokens, so `outputBudget` returns the 768 ceiling. The rewrite needs ≈1,000
tokens. mlx-swift-lm stops at 768 with no error and no signal; `MLXEngine` cannot distinguish that
from EOS. The truncated text is ~60% of the original, so `ratio` is well under 3 and the validator
passes it. `ReplacementService` sets it as the selected text.

Consequence: the back half of the user's paragraph is deleted and replaced with a sentence that stops
mid-word. There is no Everest-side undo, and `.success` auto-dismisses after 1.2 s, so nothing on
screen says anything went wrong. Crossover is roughly 3,000 characters (768 tokens × ~4 chars/token);
the band between there and the 8,000-character capture cap is the exposure.

The 768 ceiling is deliberate and tested (`EngineLimitsTests`, `outputBudget(inputTokens: 2000) == 768`).
The defect is that it is not reconciled with the 8,000-character capture limit, and nothing detects
the truncation. A test cannot reach it because the truncation happens inside the decoder.

Confidence: high on the arithmetic and the code path. The only thing I did not run is a real model.

## 2. A model download cannot be cancelled, and the panel resurrects itself with the key monitors gone — TRACED

- `EverestKit/Sources/AppCore/RewriteCoordinator.swift:179-189` — `prepare` runs the download in an
  unstructured `Task` and drains progress in `for await fraction in progress.stream`. **No generation
  check in that loop, and nothing cancels `preparing`.**
- `EverestKit/Sources/AppCore/RewriteCoordinator.swift:116-121` — `supersede()` cancels `active`,
  which is the *engine's stream* task (`TransactionBox`), never the download.
- `EverestKit/Sources/Overlay/FloatingPanelController.swift:125-132` vs `:87-102` — `dismiss()` clears
  `armedMonitors` and calls `surface.hide()`; `update(_:)` then sets `state` non-nil and calls
  `render` → `surface.present(...)` again, and **does not re-arm the monitors**.

Sequence: first run, no weights on disk. Press the hotkey; the panel shows "Preparing model". Press
Escape → `cancel()` bumps the generation and dismisses the panel. The download Task is untouched and
its next progress callback calls `panel.update(.preparing(progress:))`, which re-presents the panel.
Escape is now dead, because the `NSEvent` monitors were released by `dismiss()` and only `show()`
re-arms them. Every subsequent Escape is ignored; every click on the `esc Cancel` hint dismisses the
panel for one progress tick. When the 2.3 GB finishes, `run` returns at the generation guard and the
panel is left showing "Preparing model — 100% downloaded" permanently (`autoDismissAfter` is `nil`
for `.preparing`).

Consequence: on the worst possible occasion — a user's first minute with the app — the panel cannot
be dismissed from the keyboard and several minutes of network transfer cannot be stopped.
`dismiss()` also nils `anchorScreen`, so each re-present re-samples `visibleFrame()` and the panel
hops to whichever display the pointer is on.

The only escape is clicking the `esc Cancel` row. Whether that click lands is itself unverified —
the panel is `.nonactivatingPanel` and `acceptsKey` is false in `.preparing`, and AppKit swallows the
first click into a non-key window unless a view returns true from `acceptsFirstMouse(for:)`, which
nothing here does. **Could not rule out** that there is no recovery at all.

Tested neighbours: `cancellingStopsTheGenerationAndDismissesThePanel` covers cancel during
*generating* only; `preparationProgressReachesThePanelInOrder` never cancels.

## 3. The Settings Model tab shares one engine with the hotkey path and silently kills an in-flight rewrite — TRACED

- `Everest/App/AppDelegate.swift:56` and `:69` both pass `EngineFactory.live(for:)`.
- `EverestKit/Sources/AppCore/EngineFactory.swift:85-93` — one cached engine instance per `EngineID`.
- `EverestKit/Sources/Engines/MLXEngine.swift:13,138` — one `TransactionBox` per engine;
  `EverestKit/Sources/Engines/TransactionBox.swift:18-25` — `begin` **cancels whatever it replaced**.
- `EverestKit/Sources/AppCore/ModelSettingsModel.swift:125` — `runTest` calls `engine.stream(...)` on
  that same engine.

Sequence: start a rewrite with the hotkey, then click "Rewrite the sample" in Settings ▸ Model while
it is still decoding. `runTest`'s `stream` registers its task in the shared box, which cancels the
hotkey rewrite's task. `MLXEngine` catches `CancellationError` and calls `continuation.finish()` with
no `.finished` (`MLXEngine.swift:128-131`). Back in the coordinator, the generation has **not** moved,
so `guard mine == generation` passes and `guard let finished else { return }`
(`RewriteCoordinator.swift:155`) returns silently.

Consequence: the transaction is abandoned with no terminal state. The panel is left in `.generating`
showing a half-written rewrite; `autoDismissAfter` is `nil` for `.generating`, so it sits there until
the user presses Escape. Nothing was written and nothing says so. The reverse order is the same bug
mirrored: press the hotkey while the sample is running and `runTest` finishes with `testOutput` nil
and no failure shown.

This is the only path I found where a stream ends without `.finished` at an unchanged generation,
which is exactly the case `RewriteCoordinator.swift:153-155` comments as "cancelled mid-decode".

## 4. `LoadedModel` does not prevent two concurrent loads, though its comment says it does — TRACED

`EverestKit/Sources/Engines/MLXTokenProducer.swift:95-103`:

```swift
func container(at directory: URL) async throws -> ModelContainer {
    if let container { return container }
    let loaded = try await LLMModelFactory.shared.loadContainer(...)   // actor suspends here
    container = loaded
    return loaded
}
```

Actor reentrancy: the `await` releases the actor, a second caller passes the `if let container` check
because `container` is still nil, and starts a second `loadContainer`. The comment at `:85-86` —
"An actor … because … two hotkey presses half a second apart must not start two loads of the same
2.3 GB model" — describes a guarantee the code does not provide. Reaching it needs two concurrent
`prepare` calls, which finding 3 supplies (Settings ▸ Download or "Rewrite the sample" during a
hotkey rewrite), and so does a second hotkey press during prepare, since `supersede()` never cancels
the `preparing` Task.

Consequence: two 2.3 GB (or two 17.2 GB) model loads resident at once. On a 16 GB Mac the 30B option
is an immediate memory blow-out. The same reentrancy lets two `ModelDownloader.download` calls run
against the same cache directory, each having called `clearReady` — **could not rule out** what
`HubClient` does with two concurrent snapshot downloads of one repo.

Fix shape: hold the in-flight load as a `Task` in the actor and `await` it, rather than re-checking a
stored optional after a suspension.

## 5. A failed pasteboard restore keeps the borrow, and the next line needs it — TRACED

`EverestKit/Sources/TextBridge/PasteboardTransaction.swift:155`:

```swift
guard pasteboard.changeCount == expectedChangeCount else { return false }   // no releaseBorrow()
```

Every other exit from the transaction calls `releaseBorrow()`. This one leaves it to `deinit`, which
`:169-172` explicitly says must not be relied on. In `ReplacementService.pasteReplace`
(`:126-130`) the transaction is still in scope when the very next statement calls `handOff`, which
constructs a second `PasteboardTransaction` and fails `borrow.acquire`.

Sequence: route two (an app that answers accessibility reads but refuses the write). We snapshot the
clipboard, write our scratch text, post ⌘V, and poll for up to 450 ms. During that window something
outside our process writes to the general pasteboard — the user pressing ⌘C in another app, or a
clipboard manager rewriting it. The target also fails to consume the paste. `restoreIfUnchanged`
returns false without releasing, `handOff` cannot borrow, `snapshot()` returns false with
`fidelity == .notTaken`, and `heldCause` maps that to `.clipboardBusy`.

Consequence: the user is told "the target did not accept the paste, and **another rewrite is using
the clipboard**", which is false, and the rewrite is *not* placed on the clipboard — it is held in a
`heldForManualCopy` panel they must copy by hand. The text is not lost, but the outcome is degraded
and the sentence is wrong. `ReentrancyTests` covers the borrow being released on the *successful*
restore (`theBorrowIsReleasedAfterwards`); the failed-restore path is not covered.

## 6. `chooseStyle` does not re-check the generation after capture, so `pending` can be resurrected into a newer transaction — COULD NOT RULE OUT

`EverestKit/Sources/AppCore/RewriteCoordinator.swift:71-75`:

```swift
guard let snapshot = await begin() else { return }   // begin() suspends on MainActor.run
pending = snapshot                                    // no `guard mine == generation`
await MainActor.run { panel.show(.stylePicker(...)) }
```

Every other post-suspension site in this file guards (`:132,137,142,147,152,164,212`); this one and
`run`'s `active = engine` (`:125-128`) do not.

If a second hotkey press enters the actor while `chooseStyle` is suspended inside `begin`'s
`MainActor.run`, the newer transaction's `supersede()` clears `pending`, and then the older
`chooseStyle` resumes and writes `pending` back — now stamped with the *new* generation. Because
`pickStyle` (`:89-93`) does not call `supersede()`, picking a style then enters `run` with
`mine == generation` identical to the already-running transaction's. Two `run`s share one generation:
both pass every guard, both stream, both reach `apply`. The second `apply` would almost certainly be
refused by `TargetValidator` (the selection changed under the first write), so the likely outcome is
one replacement plus a stray clipboard write and a confused panel rather than a double paste — but
the invariant "one transaction per generation" is genuinely broken.

Why I stopped at "could not rule out": every capture path blocks the main thread
(`SelectionCoordinator.swift:126` `Thread.sleep`, `ClipboardSelectionAdapter.swift:87-94`
`Thread.sleep`), and `KeyboardShortcuts` delivers on the main thread, so the second press usually
cannot be dispatched during the window. I could not construct a schedule I am sure the runtime
produces. The missing guard is real regardless and costs one line.

## 7. Measuring content height at height 1 may reset tail-following on every streamed frame — COULD NOT RULE OUT

- `EverestKit/Sources/Overlay/NSPanelSurface.swift:145-153` — `contentHeight(for:width:)` mutates the
  live `hostingView`: `setFrameSize(NSSize(width: width, height: 1))`.
- `EverestKit/Sources/Overlay/NSPanelSurface.swift:97-117` — the `boundsDidChange` observer reports
  `isScrolledToBottom(... contentHeight: self.hostingView.frame.height)`.
- `EverestKit/Sources/Overlay/FloatingPanelController.swift:70-80` — `render` calls `contentHeight`
  before `present`, ~60 times a second while streaming.

Collapsing the document view to 1 pt makes AppKit clamp the clip view's scroll origin, which posts
`boundsDidChange`. The observer then measures against a content height of 1, `isScrolledToBottom`
returns true, and `userScrolled(isAtBottom: true)` sets `followsTail = true` — undoing the user
having scrolled up to read. The notification is delivered on `OperationQueue.main`, so it lands a
runloop turn later, after `present` has restored the real height; the reset would take effect on the
*next* frame, i.e. within ~16 ms.

If this fires, the documented behaviour "streaming auto-scrolls to the tail but stops once the user
scrolls up" does not hold on a long rewrite. I could not confirm AppKit posts the notification for
this particular mutation without running it.

## 8. The focused-element ownership check is skipped on the fallback branch — TRACED, low impact

`EverestKit/Sources/TextBridge/AXSelectionAdapter.swift:40-48`. The system-wide answer is passed
through `element(_:ownedBy:)`; the `AXUIElementCreateApplication(pid)` fallback is returned unchecked.
`TextBridge/AGENTS.md` calls that pid check "a *security* check, since the exclusion list was
evaluated against that process". In practice an app element's focused element is normally owned by
that pid, so I could not name a real leak — but the invariant is stated as unconditional and is only
enforced on one of two branches.

## 9. Deleting a style indexes a `Binding` by position — COULD NOT RULE OUT, crash

`Everest/Settings/SettingsView.swift:218` iterates `ForEach(Array($settings.styles.enumerated()), id: \.element.id)`
and `:229` calls `settings.styles.remove(at: index)`. Each `$style` binding reads
`settings.styles[index]` by position. After a removal, any surviving reference to the last row's
binding (a `TextField` that is still first responder during teardown is the usual one) reads an index
that no longer exists — the standard SwiftUI "Index out of range" crash for this pattern. Settings are
persisted on every `didSet`, so nothing is lost beyond the current keystroke. Unverified: this
directory is not reachable from `swift test` and I did not build the app target.

## 10. An empty style list leaves a picker with no rows and no way forward — TRACED, low

The Prompts tab lets the user delete every style (`SettingsView.swift:228-233`; no minimum enforced).
`chooseStyle` then shows `.stylePicker(presets: [])`. Nothing crashes — `pickStyle(at:)`
(`FloatingPanelController.swift:207-210`), `moveHighlight` (`:198-202`) and `PanelKeyMap`
(`PanelKeyMap.swift:66-70`) all guard — but `.stylePicker` has `autoDismissAfter == nil`, so the empty
panel stays up until Escape, and `pending` holds the captured selection until then.

---

## Checked and found sound

Recording these so they are not re-audited.

- **`TargetSnapshot` as `@unchecked Sendable`.** It is created on the main actor inside the `capture`
  closure, returned across the hop into the actor, stored in `pending` or passed to `run`, and handed
  back to the main actor for `apply`. I found no path where two owners hold one, and no path where the
  `AXUIElement` is touched off the main actor. The only way to get two live snapshots at once is
  finding 6, and even there they are read on the main actor.
- **Monitor teardown.** `armKeyMonitor`/`disarmKeyMonitor` balance on every path;
  `dismiss()` disarms before its early return (`FloatingPanelController.swift:125-128`). The event tap
  is driven from `state.didSet` and cleared on any non-picker state and on `dismiss`.
  `CGEventTapKeyInterceptor` releases its `Unmanaged` context on both the failure and the teardown
  path. Finding 2 leaves the *panel* visible without monitors, but never a monitor without an owner.
- **The 16 MB pasteboard budget.** `data.count <= budgetRemaining` is checked before the subtraction,
  and refuses the whole borrow rather than restoring partially
  (`PasteboardTransaction.swift:79-88`). At exactly the budget it is accepted; no underflow.
- **`PanelGeometry` boundaries.** `width`, `maxHeight` and `layout`'s inset all clamp through `max(0,…)`
  and `max(margin,…)`; a zero-size or negative-origin frame produces a degenerate but valid rect.
  `isScrolledToBottom` uses `max(0, …)` so short content always reads as at-bottom.
- **Force unwraps.** Only three in the whole tree, all guarded: `AXSelectionAdapter.swift:70,178` sit
  behind `CFGetTypeID` checks, and `EngineFactory.swift:79`'s `urls(for:.applicationSupportDirectory)[0]`
  cannot be empty for a user domain lookup.
- **`OutputValidator` division by zero.** `source.count` is never 0 in production — every capture rung
  rejects empty text — and if it were, Swift yields `.infinity` and the ratio guard rejects it rather
  than trapping.
- **Secure-field ordering, range-derived refusal, revalidation, `changeCount`-gated restore.** All
  behave as `TextBridge/AGENTS.md` describes and are covered.
