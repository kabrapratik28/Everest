# Replacement: writing the rewrite back without destroying anything

Decisions and rationale for `Improve/Replacement/`. Read this before changing anything here. Written 2026-09-14, verified against macOS 26.0 / Xcode 27 / Swift 6.4.

This is the half of the app that can lose a user's work. Reading a selection is recoverable if it goes wrong; writing over the wrong text is not. Every guard here was chosen with that asymmetry in mind, and the whole directory is biased toward doing nothing when uncertain.

Read `Improve/Selection/AGENTS.md` too. The two halves were designed together.

---

## Files

| File | Role |
|---|---|
| `PasteboardTransaction.swift` | Borrows the general pasteboard and gives it back. Used by both halves of the app. |
| `TargetValidator.swift` | Proves the world still matches the snapshot. The safety gate. |
| `ReplacementService.swift` | `apply(_:to:)`. Picks a write route and reports honestly. |

`ReplaceOutcome` is declared in `Improve/Selection/TargetSnapshot.swift`, not here, because the MVP plan groups the three shared types in that file.

`SyntheticKeystroke`, which posts the Command V, lives in `Improve/Selection/ClipboardSelectionAdapter.swift` for the same reason it posts the Command C.

---

## The outcome type carries a promise

`ReplaceOutcome.copiedOnly(reason:)` means "we did not place it for you, so it is on your clipboard". `ReplacementService` never returns that case without first writing the text to the general pasteboard, through `PasteboardTransaction.writeDurable`. Every refusal path goes through one private helper so the promise cannot be forgotten in a new branch.

That write is deliberately **not** marked transient. The user is expected to paste it themselves, so it has to survive and a clipboard manager should record it. This is the opposite of the scratch write used during a paste, and the two must not be merged.

---

## Why revalidation exists

A rewrite takes seconds. A local model on a long selection can take well over ten. Three seconds is already enough time to click into another window, scroll, select something else, or switch apps entirely.

Writing into whatever happens to be focused when generation finishes means overwriting text the user never offered us, possibly in an app they are not even looking at. There is no undo on our side, and often none on theirs either: a synthetic paste lands in the target's undo stack as an ordinary edit with no hint of where it came from, so the user may not even know what to undo.

So `TargetValidator.validate` requires four identities to still hold:

1. the same process is frontmost,
2. the focused element is the same element,
3. the selected range is the same range,
4. the selected text is the same text, compared exactly.

Plus a re-check that the focused element has not become a password field, because focus can move inside the same element tree while a rewrite is in flight.

Any doubt at all resolves to "do not write". Verified: a snapshot whose recorded text no longer matches the live selection is refused, and the document is left untouched, and the user moving the selection between capture and apply is also refused.

### `CFEqual`, not `===`

Two `AXUIElement` references obtained at different moments for the same interface object are equal but not identical. Pointer comparison would report a mismatch every single time and no rewrite would ever be written back. `CFEqual` compares the underlying element identity.

### There is deliberately no age limit

`TargetSnapshot.capturedAt` exists and is deliberately never compared against a deadline. A user who has not touched anything for fifteen seconds while a local model works is still entitled to their rewrite. The four identity checks are what make the write safe. A timeout would add a second way to fail while removing none of the ways to be wrong.

**Do not add one.** If you are here because a rewrite got applied to the wrong text, the bug is in one of the four checks, not in the absence of a clock.

### `unknown` is not `matches`

`TargetValidator.compare` returns three values, not a Bool, because "the app stopped answering" is genuinely different from "the selection changed". Validation treats unknown as a refusal.

The consequence is worth stating plainly: **a selection captured through the clipboard path can never be written back automatically.** Such a snapshot has no range and the app reports no selected text, so there is no route by which to prove anything, and those apps always end in `.copiedOnly`. That is correct and intended. If we could not read the app, we cannot prove where a paste would land, and a rewrite sitting on the clipboard is a far better outcome than a paragraph destroyed somewhere off screen.

### Range-derived captures are refused before validation even runs

`apply` returns `.copiedOnly` for any snapshot with `isRangeDerived` set, and it does so *before* calling the validator. The check is early on purpose, so that nobody later reads a passing validator as evidence that such a write would be safe.

The reasoning is in `Improve/Selection/AGENTS.md` under rung 7, and the short version is: that text came from `AXStringForRange`, the Chromium off-by-one is unmitigated on that route, and revalidation would re-read through the same shifted range and agree with itself. The four-identity check detects *change*. It cannot detect a reading that was wrong from the start.

### The comparison mirrors the capture chain

`compare` checks the range, then `AXSelectedText`, then falls back to `AXStringForRange`.

That last fallback is **not** what lets a range-derived capture be written back; those are refused above, before `compare` is ever consulted for a write. It survives for two narrower jobs: confirming a normally-captured snapshot whose `AXSelectedText` has gone momentarily empty, and letting `observeConsumption` see a post-paste selection. In both cases the snapshot's text came from `AXSelectedText`, so a shifted range produces a mismatch and the conservative refusal, never a false confirmation.

---

## Two write routes, and why the first one never chains into the second

**Route one: `AXUIElementSetAttributeValue(element, kAXSelectedText, text)`,** used only where the attribute reports settable. Preferred because the app performs the replacement itself, so it lands in one undo step, respects the field's own formatting rules, and never touches the clipboard. Settability is re-checked at write time rather than trusted from the snapshot, because a field can go read-only while a rewrite generates and because `snapshot.isEditable` is a permissive hint.

**When that call returns `.success`, we return `.replaced` and stop.** No confirming read, and this is a decision rather than laziness. The only thing a confirmation could do if it came back inconclusive is fall through and paste as well, and a false negative there inserts the rewrite **twice**. A duplicated paragraph in the user's document is unrecoverable damage. A rewrite that quietly did not land is visible and the user can press the hotkey again. The asymmetry decides it. Do not add a "verify and retry" here.

**Route two: pasteboard plus synthetic Command V,** reached when an app answers accessibility reads but will not accept the write. Real web-based editors do this. Editability is re-derived live here rather than read from `snapshot.isEditable`, matching the live settability check a few lines above; having one of the pair stale invites a future edit that resolves the inconsistency the wrong way.

Route two is only ever reached after `TargetValidator` has passed, which is what makes a synthetic paste defensible at all: milliseconds earlier we proved the exact text we captured is still selected in the exact element we captured it from, so the paste replaces *that selection*. **It is never a paste at the current cursor.** An app we could not read never reaches this code.

---

## Why there is no fixed sleep after the paste

Apps differ by more than an order of magnitude in how long they take to handle a synthetic paste. Any single number is either a visible stutter for fast apps or a false failure for slow ones, and a fixed sleep also tells you nothing about whether the paste actually landed.

Instead `observeConsumption` polls `TargetValidator.compare` every 8 ms up to a 450 ms ceiling and returns the moment the selection stops matching the snapshot. A fast app is confirmed in roughly one poll. The budget is a ceiling on observation, not a delay.

**Any change counts as proof.** A paste collapses the selection to a caret and moves the insertion point, so both the range and the selected text change. Checking for a *specific* new range would mean predicting the caret offset from the length of the inserted text, and the accessibility API is inconsistent about whether those offsets count UTF-16 units or composed characters, so any text containing an emoji would fail the prediction while having pasted perfectly.

The false positive is the user moving the caret themselves inside the 450 ms window, which costs an incorrect `.replaced` label on an outcome they can see for themselves. `unknown` during polling means keep waiting, because the element answered during validation a moment earlier. Budget exhausted with the selection still intact means not consumed, and we fall back to `.copiedOnly` rather than claim an edit the user cannot see. The loop also re-checks that the target app is still frontmost, because a user who switches away clears the selection by losing focus, and that would otherwise read as a successful paste.

### The blocking is the re-entrancy guard. Do not make this async.

`observeConsumption` blocks the main thread for up to 450 ms and `pasteReplace` holds an **open `PasteboardTransaction` across that entire window**. Read as a performance problem, the obvious fix is to make it `async` and let the run loop breathe. That fix is a data-loss bug, and there is no test that would catch it.

Here is the mechanism. `apply` contains no suspension point, so the main run loop is blocked, so a second hotkey press cannot be delivered until the first rewrite finishes. Add a suspension point and a second ⌘I can arrive while the first transaction is between `writeTransient` and `restoreIfUnchanged`. The inner transaction then snapshots **our own scratch text** as if it were the user's clipboard, and later restores that. The user's real clipboard is gone, replaced by a rewrite fragment, and every changeCount check passes because from each transaction's point of view nothing went wrong.

The `changeCount` guard cannot help here: it protects against *other* writers, and under re-entrancy the other writer is us. The blocking is what makes the guard sound. The same reasoning is written down for the capture side in `Improve/Selection/AGENTS.md`; both halves depend on it.

If the 450 ms hitch genuinely has to go, the transaction has to become a process-wide resource with an owner, so that a second rewrite is refused or queued rather than allowed to nest. That is a real design change, not a keyword change.

---

## Why the pasteboard restore is conditional on `changeCount` and not on a delay

This is the guard most likely to be "simplified" by someone who has not thought about it, so here is the full case.

Both halves of the app have to borrow the general pasteboard. `PasteboardTransaction` is the apology: snapshot, do the thing, put it back.

The obvious implementation is to restore after a short delay. **A delay races the user and silently eats whatever they copied.** The user can press Command C in another window at any moment during a rewrite. If they do, and we then blindly restore, their copy is destroyed and nothing anywhere reports it. They find out later when they paste and get the wrong thing, with no way to connect it to the rewrite tool.

So the restore is gated on the pasteboard's `changeCount` still being exactly the value our step left it at. If anything at all has written the pasteboard since, their content is newer than ours and we leave it alone. Tuning the delay does not fix this: there is no delay short enough to win the race and no delay long enough to be safe, because the hazard is a user action, not a duration. Verified: with a simulated user copy landing mid-transaction, the restore declines and the user's content survives.

The transaction has two ways to set that expectation, and both are needed:

- `writeTransient(_:)` when we are the writer, during a paste.
- `expect(changeCount:)` when the *target app* was the writer, after a synthetic Command C.

### Why the snapshot captures every type on every item

Reading only `.string` is the easy version and it is wrong. A clipboard routinely carries the same content as RTF, HTML, PNG, a file URL and plain text at once. Restoring only the plain text silently downgrades a copied table to a line of tab-separated words, and the user has no way to know Everest did it.

Asking for the bytes of every declared type also forces lazy promise providers to deliver, which is a deliberate cost: a promise we did not resolve is a promise we cannot put back.

Type order within an item is preserved by storing an ordered array rather than a dictionary, because pasteboard type order is preference order. The first type a reader recognises is the one it uses, so reordering would demote rich text below plain text.

`snapshotByteBudget` caps the whole thing at 16 MB. A copied screenshot or video frame can be hundreds of megabytes and duplicating that for a two second round trip is more cost than a rewrite is worth.

### The all-dropped edge, and why the check is at the front

This was a Critical bug once. Read it before touching `Fidelity`.

When the clipboard holds one large item, the budget drops every payload and `saved` ends up empty. The old code then read `saved.isEmpty` as *"the clipboard was empty to begin with"*, cleared the pasteboard, and returned `true`. Reproduced: a 40 MB TIFF went in, an empty pasteboard came out, and the restore reported success. Worse than doing nothing, because the user got no signal at all.

Two things fix it, and the order matters:

**`Fidelity` has three states, not two.** `notTaken`, `faithful`, `lossy`. `faithful` includes the genuinely empty clipboard, which correctly restores to empty. `lossy` means real bytes were dropped. Collapsing these back into "did we save anything" is how the bug happened; an empty array is not a fact about the clipboard, it is a fact about our copy of it.

A declared type whose `data(forType:)` returns nil does **not** make a snapshot lossy, because such a type has no bytes to lose: it is a flavour AppKit derives on demand, such as `public.utf16-external-plain-text` derived from a plain string, and the same machinery re-advertises it once the base types are restored. Measured, after an earlier version of this flag cried wolf on every rich clipboard.

**The check belongs at the front, and cannot work at the back.** `snapshot()` returns a `Bool` and callers must honour it. By the time you are in `restoreIfUnchanged`, the user's bytes are already gone from your copy and off the pasteboard; there is nothing left to be careful with. So both call sites check `canBorrow` *before* anything writes:

- `ClipboardSelectionAdapter.copySelection` returns nil before posting ⌘C, because that keystroke makes the *target app* overwrite the clipboard and we would be unable to put it back.
- `pasteReplace` abandons route two before `writeTransient`.

`restoreIfUnchanged` also refuses outright on a lossy snapshot and leaves the pasteboard alone. That is a backstop for a future caller who forgets the front check, not the mechanism.

One honest consequence: `pasteReplace` falls back to `.copiedOnly`, and that outcome does overwrite the clipboard by definition, so a user with an unsavable clipboard and a route-two app still loses it. The difference is that it is now one deliberate, reported overwrite the overlay tells them about, instead of a silent wipe inside a restore that claimed to have worked. Route one never touches the clipboard at all, so most apps never reach this.

### Why our scratch write is marked, and the restore is not

Our own temporary write carries `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`, the nspasteboard.org convention that every mainstream clipboard manager on macOS honours. Without them, every single rewrite leaves a junk entry in the user's clipboard history. The markers ride on the same item as the text so they appear in `NSPasteboard.types`, which is where managers look.

`org.nspasteboard.ConcealedType` is deliberately **not** set. It means "this is a password" and some managers surface a warning for it. Transient already prevents recording, so the stronger claim would be a misuse of the convention for no additional benefit.

The **restore** is written plain, with no markers. That content is the user's own. A manager that missed the original should be able to record it, and a duplicate history entry is a far smaller harm than a manager showing our scratch text as the user's current clipboard.

---

## Why `isEditable` over-reports on purpose

`AXSelectionAdapter.isEditable` counts a known editable role as sufficient even when neither `AXSelectedText` nor `AXValue` reports settable, because real editors including WebKit `contenteditable` accept typing while reporting neither.

The failure modes are not symmetric. Over-reporting costs an attempted paste that the target ignores, which `observeConsumption` detects and reports as `.copiedOnly`. Under-reporting means refusing to help in an app where help was possible, and the user has no way to override it.

Pasting into something genuinely non-editable is not a hazard here, because `TargetValidator` has already proved the focused element reports our exact selected text. An element that does that is a text element. The validator is what makes the paste safe, not the editability heuristic.

---

## Secure input is re-checked before writing

`apply` checks `IsSecureEventInputEnabled()` again before doing anything. A password field can take focus between capture and apply. While secure input is on, synthetic keystrokes are not delivered anyway, so the paste route would fail silently rather than visibly. Accessibility permission is re-checked for the same reason: the user can revoke it mid-rewrite.

---

## Sandbox: this code cannot work in a Mac App Store build

`AXUIElementSetAttributeValue` and `AXUIElementCopyElementAtPosition` do not function under App Sandbox **even when the user has granted Accessibility permission**. The prompt never appears and `AXIsProcessTrusted()` returns false permanently. Route one is dead outright, and route two loses its safety gate because the validator cannot read anything either, which would leave a blind paste as the only option and that is not acceptable.

There is no degraded sandboxed mode worth shipping. Do not add `com.apple.security.app-sandbox`. If you are asked to make this sandbox-compatible, say plainly that it means deleting the feature.

---

## What is verified, and how

Run against real apps on macOS 26 during implementation, with throwaway harnesses outside the repo. There is no Xcode project yet (Task 5) and no XCTest target here.

`PasteboardTransaction`, against a real private pasteboard: multi-item multi-type round trip with byte-exact data and preserved type order; declining to restore when something else writes mid-transaction, leaving that content intact; empty-clipboard round trip; `abandon` leaving our text in place; transient and auto-generated markers present on our write and absent after restore; durable writes carrying no markers.

End to end against TextEdit: the accessibility write route replacing the selection and the document actually changing; a stale snapshot being refused with the document untouched and the rewrite landing on the clipboard; the user moving the selection between capture and apply being refused; and the full paste route, meaning transient write, synthetic Command V, consumption observed through `compare`, the document showing the paste, and the user's clipboard restored afterwards.

The all-dropped budget edge, against a private pasteboard carrying a 40 MB TIFF: `snapshot()` returns false, `fidelity` is `.lossy`, `restoreIfUnchanged` returns false **without clearing**, all 40 MB are still there afterwards, and the change count never moved. `copySelection` declines on the same clipboard without posting a keystroke. A 1 MB payload, comfortably under the budget, still round-trips byte for byte, so the guard did not simply disable the feature.

Not verified live: behaviour against an app that answers accessibility reads but refuses the `AXSelectedText` write, since TextEdit accepts the write and the paste route had to be exercised by composing its parts. The parts are all proven; their assembly inside `pasteReplace` is read but not executed. Treat that function as the least proven code here.
