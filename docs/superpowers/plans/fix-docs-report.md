# TextBridge — Google Docs capture, plus four audited defects

**TextBridge: 65 → 73 tests, all passing.** Doc at exactly 60 lines.

Six commits below, all built. Bug B's late restore is now in (commit 6) after
approval; the earlier revision of this report recommended it and did not build
it.

One thing is **not** built and needs sequencing: the oversize-clipboard capture
error. `CaptureError` is switched with no `default`, exactly the trap you
warned about, so the TextBridge half is not separable from an AppCore edit. The
design and the sentence are at the end, ready to apply.

---

## Commit 1 — Google Docs capture reaches the clipboard fallback

`Sources/TextBridge/SelectionCoordinator.swift`
`Sources/TextBridge/Seams.swift`
`Sources/TextBridge/AXSelectionAdapter.swift` (`characterCount`)
`Sources/TextBridge/TargetSnapshot.swift` (`.nothingCaptured`)
`Tests/TextBridgeTests/CaptureChainTests.swift`
`Tests/TextBridgeTests/StrategyCacheTests.swift`
`Tests/TextBridgeTests/Doubles.swift`
`Sources/AppCore/CaptureFailure.swift` + `Tests/AppCoreTests/RewriteCoordinatorTests.swift`
— **now `fix-settings`' files**; see "Handover notes"

### Root cause

Measured against real Chrome 153, on a page built the way Docs is built
(canvas-painted prose, focus parked in an empty `contenteditable` in an
offscreen iframe):

```
canvas shape:  AXSelectedText=""              AXSelectedTextRange={0, 0}   AXNumberOfCharacters=0
DOM control:   AXSelectedText="quick brown fox"  AXSelectedTextRange={4,15}   AXNumberOfCharacters=44
```

`AXSelectedTextRange` is **present and zero-length, not absent** — that is the
whole bug. `readViaAccessibility` did `throw CaptureError.noSelection`, not
`return nil`, so a zero-length range ended the *whole chain* and rungs 7, 8 and
9 were unreachable. Docs was never skipped by a cache or beaten by a bad
answer; the clipboard was never reached.

The guard was right and is still there — it was being applied to an element
with no text in it, where a zero-length range is a true answer to a question
nobody asked. It now needs positive evidence (`AXNumberOfCharacters == 0`,
a definite zero, not a missing one), and hands off instead of stopping. No app,
URL or title keying: the discriminator is a property of the element.

Two consequences handled in the same commit: `.clipboard` is recorded only for
an app whose tree stayed dark (Chrome is one bundle id for Docs *and* Gmail),
and the chain's terminal error is now `.nothingCaptured` rather than
`.noSelection`, so a user who *has* selected text is not told to select some.

Full RED/GREEN for this commit is in the previous revision of this report and
summarised here:

| Behaviour | RED | GREEN |
|---|---|---|
| zero-length range in a textless element hands off | `Caught error: .noSelection` | 66 pass |
| cache must not pin Chrome to ⌘C | `snapshot.text == "quick brown fox"` failed — Gmail got the Docs reading | 67 pass |
| running out of rungs ≠ empty selection | `expected ".nothingCaptured" ... ".noSelection" was thrown instead` | 68 pass |
| a missing character count is not a zero one | `an error was expected but none was thrown` — it had returned the **stale clipboard** | 69 pass |

---

## Commit 2 — a slow ⌘C no longer destroys the user's clipboard

`Sources/TextBridge/ClipboardSelectionAdapter.swift`
`Sources/TextBridge/PasteboardTransaction.swift` (`abandon()`)
`Tests/TextBridgeTests/ClipboardSelectionAdapterTests.swift`

Audit finding A, confirmed. `copySelection` returned the moment the 400 ms copy
budget expired, without restoring. A target answering later still wrote the
user's clipboard, and by then nobody was watching: clipboard gone for good, and
the user's selected text left on the general pasteboard for any history app.

**This is not a pathological app.** Measured against real Chrome, the first
synthetic ⌘C after launch took **262 ms of the 400 ms budget**:

```
attempt 1: captured="The quick brown fox" in 0.261618292 seconds
attempt 2: captured="The quick brown fox" in 0.0167305 seconds
```

A budget bounds how long we *wait*, never how long we stay responsible. There
is now one watch over `copyBudget + settleBudget` and one give-back. The two
budgets keep their separate meanings; they are just spent on one deadline.

RED:
```
✘ Test "a copy that lands after the copy budget is still read and still put back"
  ClipboardSelectionAdapterTests.swift:94: Expectation failed: captured == "the selection"
  ClipboardSelectionAdapterTests.swift:95: Expectation failed: pasteboard.string(forType: .string) == "the user's clipboard"
✘ Test run with 70 tests in 10 suites failed after 0.407 seconds with 2 issues.
```
Both halves of the harm in one failure: the capture lost *and* the clipboard
destroyed.

GREEN: `✔ Test run with 70 tests in 10 suites passed after 0.571 seconds.`

**`abandon()` and its mutation check.** Restoring on the nothing-moved path
would have been simpler, but it rewrites identical bytes, bumps `changeCount`,
and leaves a duplicate clipboard-history entry for every hotkey press in an app
that cannot answer. `abandon()` ends the borrow without writing. That choice
was unpinned production code, so I pinned it by strengthening the existing
never-moved test with `changeCount == before` and proved the assertion has
teeth by mutation **on a copy at `/tmp/everest-mutate`, never the shared tree**:

```
mutated: nothing-moved path restores instead of abandoning
✘ Test "returns nil rather than the stale clipboard when nothing was copied"
  ClipboardSelectionAdapterTests.swift:52: Expectation failed: pasteboard.changeCount == before
✘ Test run with 70 tests in 10 suites failed after 0.553 seconds with 1 issue.
```

---

## Commit 3 — a declined restore gives the borrow back

`Sources/TextBridge/PasteboardTransaction.swift`
`Tests/TextBridgeTests/PasteboardTransactionTests.swift`

Audit finding C, confirmed exactly as described. `restoreIfUnchanged` returned
on the change-count path without releasing, so `pasteReplace`'s `handOff` on
the very next line could not acquire and returned
`.heldForManualCopy(.clipboardBusy)` — "another rewrite is using the
clipboard", which was false, withholding the rewrite instead of copying it.

RED:
```
✘ Test "a restore that declines still gives the borrow back"
  PasteboardTransactionTests.swift:125: Expectation failed: handOff.snapshot()
✘ Test run with 71 tests in 10 suites failed after 0.523 seconds with 1 issue.
```

GREEN: `✔ Test run with 71 tests in 10 suites passed after 0.686 seconds.`

I checked the other exits rather than fixing by pattern: `snapshot`'s lossy
path, `writeDurable`, `abandon` and the successful restore all release, and the
`fidelity != .faithful` exit cannot be holding one. Adding a release there
would be dead code, so I did not.

---

## Commit 4 — the per-app focus fallback is ownership-checked

`Sources/TextBridge/AXSelectionAdapter.swift`
`Tests/TextBridgeTests/AXSelectionAdapterTests.swift`

The hole was in the branch that exists *because* the system-wide query is
unreliable — the one ordinary apps take on macOS 26 — so "low impact" understates
how often that branch runs. The decision is now split out as
`focused(systemWide:perApp:ownedBy:)`, matching how `isEditable` is already
handled in this file; `perApp` is an autoclosure so the short-circuit survives,
since it is a synchronous cross-process call.

RED, first as a compile failure (`value of type 'AXSelectionAdapter' has no
member 'focused'`), then behaviourally, with the extracted method reproducing
today's unchecked fallback:
```
✘ Test "the per-app fallback is ownership-checked too, not just the system-wide answer"
  AXSelectionAdapterTests.swift:44: Expectation failed: adapter.focused(systemWide: stray, perApp: stray, ownedBy: 501) == nil
✘ Test run with 72 tests in 10 suites failed after 0.490 seconds with 1 issue.
```

GREEN: `✔ Test run with 72 tests in 10 suites passed after 0.480 seconds.`

---

## Commit 5 — `Sources/TextBridge/AGENTS.md`

Records the *why* for each of the above, per the new policy. Three existing
rows rewritten rather than four added, to stay at 60 lines:

- The `AXSelectedText == ""` fact now carries the canvas-rendering fact — what
  canvas does to the AX tree, and the measured Chrome values — so the extra
  branch does not read as redundant defensiveness.
- The cache guard records that one Docs capture must not make Gmail take the
  clipboard path for ten minutes.
- The restore guard now covers all three borrow-lifetime defects as one
  decision: a budget bounds waiting, not responsibility; restore only if
  something wrote; declining is still a logical end.
- The `AXFocusedUIElement` fact records that both branches are checked.
- Bug B is recorded as known and unfixed, with the reason it is a trade.

---

## Commit 6 — a late paste inserts the rewrite, not the user's old clipboard

`Sources/TextBridge/ReplacementService.swift`
`Tests/TextBridgeTests/ReplacementTests.swift`

EVE-009's paste half. Approved after the investigation below.

**It has to block, and here is what it turned out to be.** You asked whether
the wait could be awaited off the main actor so the cost is bookkeeping rather
than a hitch. It cannot, for three reasons that are all about the tail rather
than about the wait:

1. **The borrow would outlive the return.** The transaction holds it until the
   restore, so a second hotkey press inside the window gets
   `.heldForManualCopy(.clipboardBusy)` — "another rewrite is using the
   clipboard", which is false; nothing is using it, we are waiting. Blocking
   makes that press simply wait, which is what the user expects.
2. **The restore would be owed by a task nobody awaits.** Quit inside the
   window and the user's clipboard is stranded holding our rewrite. That is a
   new unrecoverable loss introduced by the fix for one.
3. **It is the design change the file already names.** `pasteReplace`'s comment
   says a suspension point there needs the transaction to become a
   process-wide resource with an owner first. Doing it properly is that change,
   not this one.

So `hold(until:)` blocks, and all three reasons are in the code.

**The cost, precisely.** Route two's *success* path goes from returning on the
first poll to always spending the full `consumptionBudget` — about 8 ms to
450 ms in production. Route one is untouched, `handOff` is untouched, and the
already-slow failure path is unchanged because `observeConsumption` had
already spent the budget. So: every successful rewrite in a web editor is
~450 ms slower. If that proves too visible, the tighter bound is
event-*delivery* latency rather than app-*response* latency, which is much
shorter — but that would be a new magic number, and the budget is one we have
already reasoned about, so I used it.

RED — the late paste read the user's old clipboard:
```
✘ Test "a late paste reads the rewrite, never the clipboard we were about to restore"
  ReplacementTests.swift:155: Expectation failed: reader.text == "the rewrite"
✘ Test run with 73 tests in 10 suites failed after 0.582 seconds with 1 issue.
```

GREEN: `✔ Test run with 73 tests in 10 suites passed after 0.963 seconds.`

The test drives it the way it actually happens: a selection that moves for a
reason that is not our paste, so consumption is read on the first poll while
the ⌘V is in flight, and a background reader records what the pasteboard held
when that ⌘V finally arrived. It asserts on the bytes the target would have
inserted, not on the outcome.

**What this does not fix, on purpose.** The false positive itself stands —
`apply` still returns `.replaced` when the selection merely moved. Tightening
that is the table below, and it is still a bad trade. What is gone is the
silent wrong write that used to follow it.

Your framing is in `AGENTS.md` rather than mine, because it is the better one:
the two costs are not the same kind of bad. I had weighed them as symmetric
unrecoverables and they are not — one is a write the user never asked for and
cannot undo from here, the other is a paste they performed, see immediately,
and fix by copying again.

---

## Bug B — the investigation that preceded commit 6

Audit finding B. You asked me to establish whether it is real before building.
**It is real.** A throwaway probe (added, run, removed — not left in the suite):

```
PROBE outcome = replaced
PROBE document still holds = the original
PROBE writes performed = []
```

`apply` returned `.replaced` with zero writes and the user's text untouched.
The scenario is a selection that merely *moved* while still holding the user's
original text — a reflow, a scroll, an async relayout. A real paste would have
replaced the text and collapsed the selection; `observeConsumption` cannot tell
the difference because it accepts **any** change as proof, which the code says
it does on purpose.

The second half of the audit's claim follows from the ordering: false positive
→ `restoreIfUnchanged()` puts the user's clipboard back → our ⌘V lands
afterwards → the app pastes the user's *old clipboard* into their document,
and we already reported `.replaced`.

**Why I did not fix it.** Every tightening I could find trades one unrecoverable
failure for another:

| Change | Removes | Introduces |
|---|---|---|
| Require the selection to have collapsed | reflow/scroll false positives | select-after-paste editors report not-consumed → `handOff` → rewrite is pasted **and** copied, user duplicates it |
| Verify the document contains our text | most false positives | a large `AXValue` read per rewrite; fails closed on apps that do not expose it, same duplicate risk |
| **Restore only after the full consumption budget** | the wrong-content paste entirely — a late ⌘V within the budget inserts *our* rewrite, which is correct | an unconditional ~450 ms hitch on route two, removing the early exit the code deliberately added |

`AGENTS.md` already records the project's position — false positives are
preferred because a false negative can duplicate a paragraph unrecoverably — so
this is reversing a considered trade in the highest-risk file, not patching an
oversight.

**The third row was approved and is commit 6.** The first two rows remain
rejected, for the reason in the table: both turn a visible failure into a
duplicated paragraph.

---

## The rung-9 question — which of your three candidates it was

**Candidate 3: rung 9 was genuinely not reached.** That is the commit-1 bug and
it is fixed. The other two are disproven by measurement, not reasoning.

**Candidate 1, `SyntheticKeystroke` not delivering — disproven.** Nine real
captures against live Chrome using the production `SyntheticKeystroke`, a real
`CGEvent`, and the real general pasteboard. 9/9 succeeded, 17–262 ms.

**Candidate 2, the borrow refused — disproven as the cause, but it is a real
masking path and you should know about it.** With an oversize clipboard the
capture fails silently and reproducibly:

```
=== warm, normal clipboard ===
CAPTURED: "The quick brown fox"          clipboard RESTORED
=== warm, 20MB screenshot on clipboard ===
REFUSED: nothingCaptured                 clipboard RESTORED
=== and again, to see if it is sticky ===
REFUSED: nothingCaptured                 clipboard RESTORED
```

So **a user with a screenshot on their clipboard is told Google Docs cannot be
read**, which is false — the truth is "your clipboard is too large to borrow
safely". The replace side already distinguishes this as
`HoldCause.clipboardTooLarge`; the capture side collapses it into
`.nothingCaptured`. The refusal itself is correct and protective — it happens
*before* ⌘C is posted, which is why nothing is destroyed — it is only the
reporting that lies.

### Commit 7 — applied, after sequencing

`Sources/TextBridge/Seams.swift` (`ClipboardCapture`)
`Sources/TextBridge/ClipboardSelectionAdapter.swift`
`Sources/TextBridge/SelectionCoordinator.swift`
`Sources/TextBridge/TargetSnapshot.swift` (`.clipboardUnavailable`)
`Sources/TextBridge/AGENTS.md`
`Tests/TextBridgeTests/` — `Doubles`, `CaptureChainTests`,
`ClipboardSelectionAdapterTests`, `ReentrancyTests`
`Sources/AppCore/CaptureFailure.swift` + `Tests/AppCoreTests/RewriteCoordinatorTests.swift`

**TextBridge 74 green, AppCore 58 green.** Applied with `Edit` against exact
anchors rather than copying the scratch copy over, so a moved anchor would
have failed loudly instead of clobbering; none had moved.

Checked as you asked: **`CaptureFailure.message(for:)` switches `CaptureError`
exhaustively with no `default`**, so adding a case breaks the AppCore build for
everyone. That made the TextBridge half **not separable** — adding the case
alone breaks the build, and adding the seam change without the case leaves dead
information the Iron Law would reject. One change across two modules, which is
why it waited for `fix-settings` to be out of the file.

**Prepared and proven on a scratch copy at `/tmp/everest-cand2`, not applied.**
The whole cycle has been run there: **TextBridge 74 green, AppCore 57 green**.
Applying to the shared tree is now a handful of targeted edits and one verify,
not fifteen minutes of discovery.

Behavioural RED from the dry run:
```
✘ Test "a clipboard too large to borrow is reported as that, not as an unreadable app"
  CaptureChainTests.swift:237: Expectation failed: expected error ".clipboardUnavailable"
  of type CaptureError, but ".nothingCaptured" of type CaptureError was thrown instead
✘ Test run with 74 tests in 10 suites failed after 0.944 seconds with 1 issue.
```
GREEN: `✔ Test run with 74 tests in 10 suites passed after 0.949 seconds.`

**One thing the dry run caught that I would have missed.** There is a third
call site, `ReentrancyTests.swift:133`, where a capture is deliberately nested
inside a replacement to prove the exclusion holds across both halves of the
app. It asserted `captured.value == nil`; it now asserts `== .unavailable`,
which is a strengthening — the nested capture is told *why*, which is the whole
point of the change.

That site also corrected me. I had written that an already-held borrow is
"unreachable" in capture; this test reaches it on purpose. The one-case design
still stands, because in production capture blocks the main thread so only the
too-large cause can reach a user — but the enum comment now says that, rather
than claiming the path does not exist.

Everything needed is below.

**TextBridge (mine).** `ClipboardCapturing.copySelection(pid:) -> String?`
currently collapses two different facts into `nil`: "⌘C produced nothing" and
"the clipboard could not be borrowed". The second needs to survive to the
coordinator, so the seam returns a small enum instead, and `runCaptureChain`
throws `CaptureError.clipboardUnavailable` rather than `.nothingCaptured`.
One case, not two — `Fidelity` distinguishes too-large from already-borrowed,
but capture runs blocking on the main thread so "borrowed" is not reachable
there, and a second case would be returned by no real path.

**AppCore (`fix-settings`).** One `case` in the switch:

```swift
case .clipboardUnavailable:
    "Everest reads some apps by copying, and it will not do that while your clipboard holds something too large to put back — a screenshot or an image, usually. Copy a word of text to replace it, then press the shortcut again."
```

It names the real cause and a remedy the user can act on. The current
behaviour sends someone with a screenshot on their clipboard hunting for a
Google Docs permission that does not exist.

### Before/after, same live page

```
pre-fix build:   REFUSED: noSelection        clipboard RESTORED
post-fix build:  CAPTURED: "The quick brown fox"
                 range=nil  isRangeDerived=false  isEditable=false
                 clipboard RESTORED
```

And after all four fixes, both shapes in the same Chrome process, back to back
— the canvas page, then the DOM page, which is the Gmail regression guard
verified live rather than at the seam:

```
canvas:  CAPTURED: "The quick brown fox"  range=nil     isEditable=false  role=nil
DOM:     CAPTURED: "quick brown fox"      range={4,15}  isEditable=true   role=AXTextArea
```

---

## Handover notes

- **`CaptureFailure`'s stale header is already fixed** — `fix-settings` landed
  it while I was working. It now says "Deliberately not a count: this said
  'five' through the addition of a sixth, which is how a comment stops being
  read," which is better than restating the number.
- **No new files.** Everything above is edits to files that already existed.
- **The `.nothingCaptured` sentence names Google Docs and nothing else.** It
  never mentioned Terminal or PDF, so `tdd-bridge`'s correction needed no
  change. Worth keeping that trap written down somewhere: those are
  *replacement* limits from root §3, where accessibility answers fine and there
  is simply no editable buffer, so they land in `.copiedOnly` and have nothing
  to do with this case.
- I ran **no git commands** after your policy message.

## Needs manual verification against real Chrome

The architecture is modelled faithfully and Chrome's answers to it are
measured, but a real signed-in document is the last step:

1. Real Doc, select a paragraph, hotkey → expect `.copiedOnly`.
2. Then Gmail in the same window within ten minutes → expect in-place, not
   copy-only.
3. Doc with nothing selected → expect the `.nothingCaptured` sentence.
4. Copy a sentinel, rewrite in Docs, confirm the clipboard comes back.
5. **IME composition.** Docs' hidden input is empty at rest but receives text
   mid-composition, which would make it report a non-zero character count and
   restore the old `.noSelection` refusal. Harmless — a refusal, never a wrong
   rewrite — but it would read as flakiness.
6. A deliberately slow or huge selection, to exercise commit 2's late-copy path
   against a real app rather than a fake.

Probe and harnesses are in `/tmp/everest-probe/` (`axprobe.swift`,
`harness.swift`, `latecopy.swift`, `canvas-doc.html`, `dom-doc.html`). `/tmp`
is ephemeral — copy them out if they are worth keeping.
