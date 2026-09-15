# Fix: F1 — the envelope regex matched any hex run

**One commit.** Files:

| File | Change |
|---|---|
| `EverestKit/Sources/RewriteCore/OutputValidator.swift` | `{16}` not `+`; close tag matched by the open tag's own id; doc stops over-claiming |
| `EverestKit/Tests/RewriteCoreTests/CoreTests.swift` | the guarding test given a payload that can fail |
| `EverestKit/Sources/RewriteCore/AGENTS.md` | 59 lines, edited in place |

All three of your points verified against disk before I touched anything, and
all three hold. `identifier()` does zero-pad to exactly 16
(`PromptBuilder.swift:42`), so `{16}` is exact rather than a guess.

---

## What it did

`/<selected_text_[0-9a-fA-F]+>/` matches `<selected_text_1>`.

**RED:**

```
✘ "OutputValidator.clean leaves selected_text tags that are the user's own text"
  CoreTests.swift:100:5
↳ OutputValidator.clean(idShaped, …) → "inner"
↳ idShaped → "Keep this. <selected_text_1>inner</selected_text_1> And keep this too."
```

70 characters in, 6 out, and those 6 are what `apply` writes to the document.
With the ratio gone there is no length floor left to catch it.

## The fix

Both of the things you suggested, because the second is nearly free once the
first is in place:

- **`[0-9a-fA-F]{16}`** — the width `identifier()` actually emits.
- **The closing tag is found by the opening tag's own id**, as a literal
  string search rather than a second pattern. Two independent patterns accept
  a close carrying a *different* id from the open, which is not an envelope at
  all — just two tag-shaped things in someone's text.

A false positive now needs a user's own text to contain a 16-hex-digit tag
*and* a closing tag with that same id, exactly once each.

**The doc no longer claims construction-level safety.** It says vanishingly
unlikely, not impossible, and says so in the imperative — *do not write it up
as "by construction" again* — because that claim is exactly what stopped
anyone reading the pattern underneath it.

## On the test that could not fail

You are right that this is the third time in one function, and the shape is
identical each time: the injection escape survived behind a test whose payload
contained no delimiter; the dead literal strip survived behind a test using
the bare tag; this survived behind the same bare-tag payload.

The common factor is that **the payload was chosen to look like the thing
being defended against rather than to exercise the code that defends**. A bare
`<selected_text>` cannot match a pattern that requires `_` and an id, so no
version of that pattern was ever under test.

The test now carries both payloads in one case — the bare tag, which pins that
literal stripping never returns, and the id-shaped one, which is the assertion
with teeth. Only the second can fail, and it did.

## GREEN

```
RewriteCoreTests   ✔ 19 tests passed
EnginesTests       ✔ 32 tests passed
AppCoreTests       ✔ 59 tests passed
TextBridgeTests    ✔ 74 tests passed
OverlayTests       ✔ 69 tests passed
```

## Process note

My first GREEN attempt failed to compile and I very nearly reported a stale
pass: I had written `swift build … | grep … && xcrun xctest …`, and **the pipe
hands `&&` grep's exit status, not the build's**. The build failed, grep
matched the word "error" and succeeded, and xctest duly ran the previous
bundle. Root §8's rule is to issue build and test as one `&&` command — worth
adding that piping the build through anything defeats it.

---

# Judgement: `chooseStyle` and `run:128` are one bug, and B alone is enough

**Not two findings at two ends of a thread. One root cause with two entry
points, and the more dangerous one is the entry point I did *not* find.**

The invariant is "one transaction at a time; a superseded transaction touches
nothing", with `generation` as the token. The defect is that **the token is
never bound to the transaction.** It is sampled at arbitrary later points, so
a transaction can pick up a generation belonging to somebody else:

- **`run` samples at entry** (`:128`), not at `begin()`. Anything that
  supersedes in between is adopted.
- **`chooseStyle` writes `pending` after a supersede**, so the payload
  outlives the generation that produced it.

One supplies a fresh token, the other a stale payload, and the guards compare
token to token — so a recombination passes all of them, including the one
before `apply`.

**The part that changes what you dispatch: `run:128` is independently
sufficient, and it is reachable on `quickImprove`, not the picker.**

```swift
guard let snapshot = await begin() else { return }          // sets generation N
let preset = await MainActor.run { settings.quickImprove }  // ← suspension
await run(snapshot: snapshot, preset: preset)               // samples generation *now*
```

A second press superseding during that `settings.quickImprove` read leaves the
first transaction sampling the *new* generation. Two `run`s, same token, both
passing every guard — with no style picker involved. My `chooseStyle` finding
is the same thing reached through a second door.

**So fixing `chooseStyle` alone would be worse than not fixing it**: it closes
the door I happened to find, leaves the primary path open, and marks the item
done. Whereas binding the token at `begin()` and carrying it with the
transaction — including inside `pending` — closes both, because a resurrected
snapshot would then carry its own stale generation and be refused.

That also retires my "could not rule out". I could not construct a schedule
for the picker race because capture blocks the main thread; the `quickImprove`
window needs no such luck, because the suspension is a plain `MainActor.run`
for a settings read with nothing blocking behind it.

**On the accidental containment:** `TransactionBox` only saves us while both
`run`s resolve the same `EngineID`, since the memoised engine is what gives
them one box to fight over. Switch model between presses and they get separate
engines, separate boxes, and both reach `apply`. What stops the *document*
being written twice at that point is `TargetValidator` revalidating and
refusing — a different subsystem, doing a job this invariant was supposed to
have already done. Two accidents deep is not containment.

Not built, as asked.
