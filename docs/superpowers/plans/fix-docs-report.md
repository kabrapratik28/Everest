# Google Docs capture — root cause and fix

**Status: both bugs fixed.** TextBridge 65 → 69 tests, all passing. AppCore 45,
all passing. Verified end to end against real Chrome 153, before and after, on
the same live page in the same minute.

Scope note up front: **two files outside my declared scope were edited**, both
forced by the fix and both minimal. See "Out of scope, edited anyway".

---

## 1. What I verified rather than assumed

The canvas premise is correct, and I measured what it actually produces instead
of reasoning about it. Chrome was not running, so I built the architecture
faithfully in a local page — prose painted into `<canvas>`, keyboard focus
parked in an empty `contenteditable` inside a 1×1 offscreen iframe, which is
Docs' `docs-texteventtarget-iframe` — and probed Chrome's real AX tree with a
throwaway binary. Temp Chrome profile, `file://` URL, no sign-in, no network,
no touching the user's profile.

**Canvas shape (the Docs architecture), Chrome 153:**

```
role=AXTextArea  subrole=nil  desc=text entry area
AXSelectedText="" (len 0)  err=0
AXSelectedTextRange={loc 0, len 0}  err=0
AXNumberOfCharacters=0
AXValue="" (len 0)
```

**DOM control (the Gmail shape), same Chrome, same second:**

```
AXSelectedText="quick brown fox" (len 15)  err=0
AXSelectedTextRange={loc 4, len 15}  err=0
AXNumberOfCharacters=44
AXValue="The quick brown fox jumps over the lazy dog." (len 44)
```

That is the whole of why Gmail works and Docs does not: Gmail answers rung 5,
Docs answers rung 6 with a range about the wrong element.

The decisive detail the premise did not predict: **`AXSelectedTextRange` is
present and zero-length, not absent.** Absent would have fallen through to ⌘C
and Docs would already work. Present-and-zero is what kills it.

## 2. Root cause

`SelectionCoordinator.readViaAccessibility` had:

```swift
if let range, range.length == 0 { throw CaptureError.noSelection }
```

`throw`, not `return nil`. It propagates out of `runCaptureChain()`, so a
zero-length range **ends the whole chain** — rungs 7, 8 and 9 are structurally
unreachable from there. The clipboard fallback was never skipped by a cache or
out-competed by a bad answer; it was never reached at all.

That is hypothesis shape 2 from the brief, confirmed. Shapes 1 and 3 are ruled
out: `AXSelectedText` is empty (not non-empty-but-useless), and the cache plays
no part — the chain dies before the clipboard is ever recorded, so Chrome never
had a `.clipboard` entry to be pinned to.

**The guard itself was right, and it is still there.** Its reason — "a
zero-length range is the app saying plainly that nothing is selected, and ⌘C
there rewrites whatever the user copied ten minutes ago" — holds for an element
that *has* text. It was being applied to an element with none, where it is a
true answer to a question nobody asked.

### Bug 2 is not silence, and that matters

The brief expected a path producing no user-visible message. **There is no such
path.** `capture()` either returns a snapshot with non-empty text or throws a
typed `CaptureError`, and AppCore's `begin()` maps every one to a panel. What
Docs actually produced was `.noSelection` →

> "Select the text you want rewritten, then press the shortcut again."

— which is exactly the lie the brief predicted, told to someone looking at
their own highlighted paragraph. Whether the user saw that sentence and called
it "no error", or the panel genuinely did not appear, I cannot tell from here:
Everest was not running during this session, and the panel is Overlay's.
**If a panel truly fails to appear for `PanelState.error`, that is a second
defect and it lives in Overlay, not TextBridge.** Worth handing to whoever owns
it.

## 3. The fix

Three changes in `SelectionCoordinator`, each test-driven.

**A zero-length range ends the element, not the chain.** It now needs positive
evidence of which situation it is in, via a new `AccessibilityReading` method,
`characterCount(of:)` → `AXNumberOfCharacters`:

```swift
if let range, range.length == 0 {
    guard accessibility.characterCount(of: element) == 0 else {
        throw CaptureError.noSelection
    }
    return nil
}
```

`AXNumberOfCharacters` rather than measuring `AXValue`, because the only
question is whether the element holds any text and `AXValue` would drag an
entire document across the process boundary to answer it.

Note `== 0`, not `?? 0 == 0`. A *missing* count is not a zero one; an element
that does not implement the attribute keeps the old refusal. That distinction
is pinned by a test, and the first version of the fix got it wrong — see RED 4.

Both branches return before rung 5, so **nothing is read beside the range**.
The contradiction guard (non-empty `AXSelectedText` next to a zero-length
range) survives on both paths, and rung 7 can no longer be handed a zero-length
range at all.

**No app, URL or window-title keying.** The discriminator is a property of the
element — it holds no characters — and is true of any canvas editor, not just
Docs.

**`.clipboard` is now recorded only for an app whose tree stayed dark.** This
one is a regression my own fix introduced, caught by writing its test. The
cache is keyed by bundle id, and Chrome is one bundle id for Docs *and* Gmail.
Once Docs reached rung 9 and recorded `.clipboard` against `com.google.Chrome`,
the next hotkey press in Gmail would try ⌘C first, succeed, and return
`.copiedOnly` — silently costing Gmail its in-place rewrite for ten minutes.
An app that resolved a focused element on the first ask is not the hostile app
the cache exists for.

**`CaptureError.nothingCaptured`, new case.** The final `throw` at the end of
the chain was `.noSelection`; it is now this. `.noSelection` is the *app's*
answer — an element holding text reported none of it selected — and is safe to
act on as a claim about the user. `.nothingCaptured` is *ours*: every rung
including ⌘C came back empty, and which of the two possible reasons it was is
precisely what we could not determine. Its sentence owns that instead of
picking one:

> "Everest tried every way it has to read this app — Accessibility, then a
> copy — and got nothing back. If your text is selected, this app draws it
> somewhere macOS cannot read it; Google Docs works that way. If it is not
> selected, select it and press the shortcut again."

Two remedies because the chain genuinely cannot tell which applies. Guessing
"select some text" sends half those users to reselect forever.

### Guards and constraints, all intact

- Secure-field refusal still runs first, and now runs on *more* paths than
  before: the zero-length hand-off reaches rung 8, which re-runs the subrole
  check on the revealed tree.
- Nothing weakens "never write through a range we cannot trust". A Docs capture
  comes back with `range=nil`, `isRangeDerived=false`, `isEditable=false` and no
  element identity, so `TargetValidator` returns `unknown`, which is not
  `matches`, and it can never be written back.
- A clipboard-captured selection still returns `.copiedOnly`. `ReplacementService`
  and `TargetValidator` are untouched.
- Every §6 guard in the root `AGENTS.md` is untouched.

## 4. RED and GREEN, per behaviour

Baseline before any change: `✔ Test run with 65 tests in 10 suites passed`.

### Behaviour 1 — a zero-length range in a textless element hands off

RED:
```
✘ Test "a zero-length range in an element holding no text hands off instead of stopping"
  recorded an issue at CaptureChainTests.swift:78:6: Caught error: .noSelection
✘ Test run with 66 tests in 10 suites failed after 0.404 seconds with 1 issue.
```

GREEN (after the two existing zero-length fixtures were given coherent
character counts — see §5):
```
✔ Test run with 66 tests in 10 suites passed after 0.394 seconds.
```

**Mutation check, on a copy at `/tmp/everest-mutate`, never the shared tree.**
The `ax.textReads == 0` assertion never failed during RED — the test died on
the thrown error first — so it had not been observed to have teeth. Mutating
the guard into the obvious one-line simplification (`if ... , count > 0 { throw }`,
falling through to rung 5 instead of handing off):

```
mutated: zero-length branch falls through to rung 5 instead of handing off
✘ Expectation failed: snapshot.text == "the sentence painted on the canvas"
✘ Expectation failed: ax.textReads == 0
✘ Test run with 68 tests in 10 suites failed after 0.420 seconds with 2 issues.
```

It has teeth: the simplification would let a contradictory `AXSelectedText`
through, and the test catches it.

### Behaviour 2 — the cache must not pin Chrome to ⌘C

RED:
```
✘ Test "a clipboard capture in an app whose tree answers does not pin the app to ⌘C"
  recorded an issue at StrategyCacheTests.swift:182:9: Expectation failed: snapshot.text == "quick brown fox"
  recorded an issue at StrategyCacheTests.swift:183:9: Expectation failed: clipboard.attempts == 1
✘ Test run with 67 tests in 10 suites failed after 0.375 seconds with 2 issues.
```

Gmail got handed the Docs reading, exactly as predicted. GREEN:
```
✔ Test run with 67 tests in 10 suites passed after 0.296 seconds.
```

### Behaviour 3 — running out of rungs is not an empty selection

RED, first as a compile failure (the test names the API into existence):
```
CaptureChainTests.swift:195:38: error: type 'CaptureError' has no member 'nothingCaptured'
error: Build failed
```

Then, with the case added and nothing else, the behavioural RED:
```
✘ Test "an app that answers nothing anywhere is not reported as an empty selection"
  recorded an issue at CaptureChainTests.swift:195:9: Expectation failed:
  expected error ".nothingCaptured" of type CaptureError, but ".noSelection" of type CaptureError was thrown instead
✘ Test run with 68 tests in 10 suites failed after 0.414 seconds with 1 issue.
```

GREEN:
```
✔ Test run with 68 tests in 10 suites passed after 0.382 seconds.
```

The AppCore half, RED — the refusal has no sentence:
```
Sources/AppCore/CaptureFailure.swift:25:16: error: switch must be exhaustive
error: Build failed
```
GREEN: `✔ Test "every capture refusal explains its own remedy" passed`.

### Behaviour 4 — a missing character count is not a zero one

This one caught a real mistake. The first version of the guard used
`(characterCount(of:) ?? 0) == 0`, treating "the element does not implement the
attribute" as "the element is empty". RED:

```
✘ Test "an element that does not report a character count keeps the plain refusal"
  recorded an issue at CaptureChainTests.swift:121:9: Expectation failed: an error was expected but none was thrown
✘ Test run with 69 tests in 10 suites failed after 0.304 seconds with 1 issue.
```

No error thrown — it had fallen through and returned the stale clipboard
string, which is the precise hazard the original guard existed to prevent.
Changed to require a definite zero. GREEN:

```
✔ Test run with 69 tests in 10 suites passed after 0.355 seconds.
```

### Final

```
✔ Test run with 69 tests in 10 suites passed after 0.530 seconds.   TextBridgeTests
✔ Test run with 45 tests in 1 suite passed after 0.050 seconds.     AppCoreTests
```

No test touches `NSPasteboard.general` and none depends on another app running.

## 5. End-to-end against real Chrome

Not a unit test — a throwaway harness linked against the real `TextBridge`,
using the real `AXSelectionAdapter`, `SystemProbe`, `ClipboardSelectionAdapter`
and `SyntheticKeystroke`, run against live Chrome on the canvas page with a
real ⌘C and the real general pasteboard. The page answers `copy` from a
listener in the focused frame, which is what Docs does.

Pre-fix build (scratch copy reverted to the original chain):
```
clipboard before: SENTINEL-1789456256
frontmost: com.google.Chrome
REFUSED: noSelection
clipboard after: SENTINEL-1789456256
clipboard RESTORED
```

Post-fix build, same live page, minutes apart:
```
clipboard before: SENTINEL-1789456219
frontmost: com.google.Chrome
CAPTURED: "The quick brown fox"
  range=nil
  isRangeDerived=false  isEditable=false
  role=nil
clipboard after: SENTINEL-1789456219
clipboard RESTORED
```

The chain reaches rung 9, ⌘C is answered, the text is captured, and the user's
clipboard is put back. `range=nil` and no element identity mean this becomes
`.copiedOnly` downstream, which is correct.

One incidental finding worth keeping: on the first attempt the harness returned
`nothingCaptured` because the model page's `copy` listener sat on the top
document while focus was in the iframe. **Chrome routes Edit ▸ Copy to the
focused frame.** That was a flaw in my fixture, not in the chain — but it is
also the shape of how this rung fails, so it is worth knowing when reading a
future bug report about ⌘C not landing in a framed page.

## 6. Genuinely impossible vs. fixed

**Impossible, and correctly so:**

- **Reading a Docs selection through Accessibility.** The text is pixels. No AX
  rung will ever see it. This is not our bug and there is no fix.
- **Replacing text in place in Docs.** A clipboard capture has no element, no
  range and no text identity, so `TargetValidator` returns `unknown` and the
  rewrite can only ever be `.copiedOnly`. Correct behaviour, not a limitation to
  chip away at.
- **Distinguishing "nothing selected" from "selected but unreadable" once ⌘C
  has also come back empty.** No signal exists. `.nothingCaptured` says so in
  words instead of guessing.

**Fixed:**

- Docs selections are captured, via ⌘C, as `.copiedOnly`.
- Gmail in the same Chrome keeps its in-place rewrite.
- The failure that remains is a sentence that names the real situation.

**Cost, stated plainly:** every Docs capture now pays the full probe — an
`AXManualAccessibility` write, a 100 ms settle, then ⌘C (≤ 400 ms budget,
returns as soon as the change count moves). Roughly 150–300 ms on the main
thread in practice. The alternative is the feature not working there.

## 7. Needs manual verification against real Chrome

Everything above used a faithful model of Docs' architecture, not Docs. The
architecture is right and Chrome's answers to it are measured, but the last
step needs a real document and a signed-in account:

1. **Open a real Google Doc, select a paragraph, press ⌘I.** Expect the rewrite
   to arrive on the clipboard with a `.copiedOnly` panel. This is the one that
   matters.
2. **Then press ⌘I in Gmail in the same Chrome window, within ten minutes.**
   Expect in-place replacement, not copy-only. That is the cache guard doing its
   job in the real world.
3. **Press ⌘I in a Doc with nothing selected.** Expect the `.nothingCaptured`
   sentence, not "select the text you want rewritten".
4. **Confirm the clipboard survives.** Copy a sentinel, rewrite in Docs, check
   the clipboard is back afterwards.
5. **One residual risk to watch:** Docs' hidden input is empty in the steady
   state but receives text during **IME composition**. If a capture is attempted
   mid-composition the element may report a non-zero character count and the old
   `.noSelection` refusal would return. Worth one try with a CJK IME mid-word.
   Harmless if it happens — a refusal, never a wrong rewrite — but it would look
   like flakiness.
6. **`AXSelectionAdapter.characterCount(of:)` has no unit test**, consistent
   with the existing rule for thin C wrappers with no decision in them. It was
   exercised for real by the harness in §5, and a wrong answer fails closed
   (the old refusal).

The probe and harness are at `/tmp/everest-probe/` (`axprobe.swift`,
`harness.swift`, `canvas-doc.html`, `dom-doc.html`) if any of this needs
re-running; `/tmp` is ephemeral, so copy them out if they are worth keeping.

## 8. Out of scope, edited anyway

Two files outside `Sources/TextBridge` and `Tests/TextBridgeTests`. Neither was
avoidable and neither is in another agent's declared area (`Overlay/`,
`Settings/`, `Engines/`):

- **`Sources/AppCore/CaptureFailure.swift`** — adding a `CaptureError` case
  breaks an exhaustive `switch`, so AppCore would not compile. The sentence is
  also the entire deliverable for bug 2; a typed cause with no words attached
  fixes nothing a user can see.
- **`Tests/AppCoreTests/RewriteCoordinatorTests.swift`** — the new case added to
  the distinctness list, test-first. This also caught a regression I caused:
  `#expect(messages[4].contains("com.1password.1password"))` was positional, and
  inserting a case at index 3 silently pointed it at `tooLong`. Changed to
  address the case directly, matching how the `tooLong` assertion beside it
  already works.

Also, `Sources/TextBridge/AGENTS.md` went to 62 lines with the canvas fact
added, over the 60 budget, so per §2 I cut rather than appended. Two merges, no
facts lost:

- The two cache guards are now one row — they are one decision, that a cached
  answer is a hint about an app and neither a gate nor a verdict.
- **Removed:** the "a `let` with a default value is excluded from Swift's
  memberwise initializer" row. It is stated verbatim, at greater length, in
  `TargetSnapshot.swift` directly above `isRangeDerived` — which is where
  anyone about to add a default is looking. Flagging it here because deleting
  someone else's hard-won note should be visible, not silent; restore it and
  cut something else if you disagree.

Now 60 lines.
