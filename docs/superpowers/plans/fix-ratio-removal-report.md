# Fix: remove the 3× ratio — and two defects found on the way

**One commit.** Files:

| File | Change |
|---|---|
| `EverestKit/Sources/RewriteCore/OutputValidator.swift` | ratio gone; blank-output refusal; envelope unwrap bounded to one pair |
| `EverestKit/Sources/AppCore/ValidationFailure+Message.swift` | `.lengthRatio` branch removed (carve-out, taken in the same write) |
| `EverestKit/Tests/RewriteCoreTests/CoreTests.swift` | 1 test deleted, 4 added |
| `EverestKit/Sources/RewriteCore/AGENTS.md` | 59 lines, two sections merged to stay under budget |

`ValidationFailure+Message.swift` was **clean** when I got there — `fix-settings`
was in onboarding, settings copy and shortcut copy, not this file. Enum and
switch changed in one write, per root §8.

RewriteCore 14 → 19 tests. All five targets green: 19 / 32 / 57 / 73 / 68.

---

## 1. The ratio, as authorised

`maxLengthRatio` and `ValidationFailure.lengthRatio` are gone. `.empty`
remains.

**RED** — an honest expansion, refused:

```
✘ "OutputValidator.validate accepts an expansion far longer than its source"
  CoreTests.swift:120:21
↳ expected .success for an honest expansion, got
  failure(RewriteCore.ValidationFailure.lengthRatio(6.689655172413793))
```

6.7× on a 29-character sentence — the shape of every `Expand` a user would
actually ask for.

`AGENTS.md` records it your way: *removed because a structural bound replaced
it, not because runaway output stopped mattering — do not put a scanner back.*

## 2. A defect in my own EVE-012, found by taking your gap-2 suggestion

**`56f671b` is marked Fixed in `EXTERNAL-AUDIT.md` and had a silent
wrong-write in it.** Worth knowing before that line is trusted.

Your argument was that the id makes leading/trailing extraction exact rather
than heuristic. **You were right about the id and it turns out I had the
weaker version.** But there is a gap in it that I only found by writing the
test for your idea, and it was already live in the code I shipped.

My whole-output regex was `<open>(.*)<close>` with `wholeMatch`. Greedy `(.*)`
plus backtracking means that when a model emits the envelope **twice** — it
restates the input, then answers — the match spans *both*: it starts at the
first open tag and ends at the last close tag, and captures

```
the original</close>\n\nHere is the rewrite:\n<open>The rewrite
```

as "the rewrite", and writes that into the document. The whole-output
constraint I was relying on does not prevent it. I asserted otherwise in my
last message; that was wrong.

**Where your reasoning needs one more clause.** The id proves a tag is *ours*.
It does not say *which pair delimits the answer* when there are two. So:

- first-open → last-close: the splice above.
- first-open → first-close: hands back the user's **own text** as the rewrite.
- leave it alone: a visible tag in the document.

Unwrapping is therefore bounded to **exactly one open and one close**. Inside
that bound your construction holds completely — everything outside the pair is
model commentary, by construction, not by judgement — so gap 2 is closed
rather than traded:

**RED**, both cases, one of them catching the shipped defect:

```
✘ "OutputValidator.clean unwraps an envelope the model followed with commentary"
  CoreTests.swift:49:5: Expectation failed: cleaned == "The report is ready."
✘ "OutputValidator.clean leaves output alone when the envelope appears twice"
  CoreTests.swift:70:5: Expectation failed: cleaned == raw
✘ Test run with 19 tests failed with 2 issues.
```

I expected only the first to fail. The second failing is the news.

## 3. Whitespace-only output was being written over the selection

Not mine, not yours, and older than both: **`"   \n\t "` passed validation and
replaced the user's text.** `.empty` meant zero characters, and blank output
is not zero characters. Replacing a selection with whitespace *deletes* it,
silently and unrecoverably — the exact class this project spends its budget
avoiding, sitting in the validator the whole time.

It surfaced because `fix-settings` had already rewritten
`rewriteCoordinatorTests.rejectedOutputIsNeverWritten` in anticipation of the
ratio removal, feeding blank output and expecting `.refused`. Their test was
failing on its own terms, against code that had never behaved that way. It
would also have failed before my change — the ratio never fired on short
output.

**RED** in my own suite, since the behaviour belongs to my module:

```
✘ "OutputValidator.validate rejects output that is only whitespace"
  CoreTests.swift:93:21
↳ expected .failure for whitespace-only output, got success("   \n\t ")
```

Refused in `validate`, not trimmed in `clean`: refusing blank output costs the
user nothing, whereas trimming everything that passes would quietly edit
rewrites that legitimately end in a newline.

**I did not touch `RewriteCoordinatorTests.swift`.** It is dirty and it is
`fix-settings`'. Fixing my own file made their test pass; AppCoreTests is 57
green.

## GREEN

```
RewriteCoreTests   ✔ 19 tests passed
EnginesTests       ✔ 32 tests passed
AppCoreTests       ✔ 57 tests passed
TextBridgeTests    ✔ 73 tests passed
OverlayTests       ✔ 68 tests passed
```

## What I would still not claim

The one-pair bound is exact for the cases above, but it is a bound on *our*
envelope, not a parser. A model that emits one open tag and no close, or
mangles the id, leaves a visible tag in the output. That is the failure mode I
chose on purpose over any guess.
