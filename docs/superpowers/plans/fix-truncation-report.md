# Fix: a truncated rewrite overwriting the user's text (audit finding #1)

Scope kept to `EverestKit/Sources/Engines/` + `EverestKit/Tests/EnginesTests/`.
**`RewriteCore` was not touched** — see "One line I did not write" for why the
fix moved out of `OutputValidator`. `TextBridge` was not touched.

---

## 1. What the decoder can actually report

**It can distinguish the two, exactly.** I read the resolved 3.31.4 checkout
rather than inferring it.

`MLXLMCommon/Evaluate.swift:1956` defines `GenerateStopReason`:

```swift
case stop       // an EOS/stop token — the model finished its sentence
case length     // the configured max token limit was reached
case cancelled  // explicit cancellation, or the fallback when it cannot tell
```

`Evaluate.swift:1891-1897` sets `.length` precisely when the iterator ended
with `tokenCount >= maxTokens`, and `:1917` yields it as
`Generation.info(GenerateCompletionInfo)` immediately before `finish()`, on
every path.

**We were throwing it away.** `ChatSession.streamResponse(to:)`
(`ChatSession.swift:498`) and `streamDetails(to:)` (`:534`) are the same
stream; `streamResponse` maps every element through `\.chunk`, which is `nil`
for `.info`. One character of the API surface was the difference between
knowing and not knowing.

So the root-cause fix was available and I took it: `MLXTokenProducer` now uses
`streamDetails`.

## 2. What I chose

Three layers. The first makes the failure rare, the second makes it detectable
exactly, the third catches it where no exact signal exists.

**a. The output ceiling is now derived, not an independent constant.**
`EngineLimits.swift`. The old `min(max(64, inputTokens * 1.4), 768)` had two
guards doing one job. `1.4 × inputTokens` is the anti-rambling guard and it
*already scales* — a model returning 1.4× its input is proportionate at any
size. The flat 768 only ever binds above ~550 input tokens, which is precisely
where it destroys text and precisely where the scaling guard was already
sufficient. Replaced with `contextCap - inputTokens`, which is the one real
limit: the prompt and the generation share the KV cache. That also fixes a
second latent bug — `maxTokens: 768` could previously be handed out alongside
`maxKVSize: 8192` with a 7,000-token prompt, overrunning the cache the same
settings asked for.

**b. `MLXEngine` refuses on `GenerationStop.budgetExhausted`.** Exact, no
inference. A new `TokenEvent` seam carries `.delta(String)` and one
`.stopped(GenerationStop)`; the adapter translates, the engine decides, which
keeps the `AGENTS.md` rule that no adapter holds an `if`.

**c. `OutputCompleteness` — source ends a sentence, output does not.**
The backstop. `AppleFoundationEngine` needs it: `FoundationModels` exposes
neither a stop reason nor a token count, so the same defect was live there with
no exact signal available. `MLXEngine` runs it too, because `stopReason` is a
dependency's promise and a version that stopped keeping it would restore the
original bug invisibly.

### The threshold, and why it does not reject honest work

**I did not use a length ratio, and I recommend against adding one.**

The obvious lower bound — reject output much shorter than its source — cannot
be set safely. `Concise` is a **built-in** style whose instruction is *"Make
this significantly shorter and more direct"*, so a correct rewrite is routinely
~40% of the original. That is the same proportion a truncation produces. No
threshold separates them, because the difference between a concise rewrite and
a truncated one is not how much text came back. It is **where the text stops**.

So the rule is: *if the source ends in sentence-terminal punctuation and the
output does not, it was cut off.* Trailing whitespace and closing delimiters
(`" ' ) ] } » ” ’ \` *`) are looked through on both sides, so a rewrite that
correctly closes a quotation or a `**bold.**` span is not mistaken for a
fragment.

It **fails open** whenever the source is not itself a complete sentence — a
heading, a list item, a cell, half a line of code, the unpunctuated note
someone is fixing. Guessing there would refuse correct rewrites of a large
share of what people actually select, and the cost of the miss is bounded,
because the default engine has the exact check.

Known limit, stated plainly: a truncation that happens to land on a full stop
passes this rule. On MLX layer (b) catches it regardless. On Apple it would
not, and I could not find a signal that would.

## 3. What a user sees at 4,000 characters

**A complete rewrite. The bug is gone rather than converted into a refusal.**

Measured against the real prompt (safety frame 463 chars + `quickImprove`
instruction 105 + tag wrapper 37 = 605 chars ≈ 151 tokens overhead), at ~4
characters per token:

| Selection | Prompt tok | Old budget | New budget | Needed | Before → After |
|---:|---:|---:|---:|---:|---|
| 500 | 276 | 386 | 386 | 125 | ok → ok |
| 1,500 | 526 | 736 | 736 | 375 | ok → ok |
| 3,000 | 901 | 768 | 1,261 | 750 | ok → ok |
| **4,000** | 1,151 | **768** | **1,611** | 1,000 | **TRUNCATED → complete rewrite** |
| 6,000 | 1,651 | 768 | 2,311 | 1,500 | TRUNCATED → complete rewrite |
| 8,000 (capture cap) | 2,151 | 768 | 3,011 | 2,000 | TRUNCATED → complete rewrite |

Every selection `TextBridge` is willing to capture now fits its own budget, so
the refusal path is not reached at all for English prose. The honest cost: an
8,000-character rewrite is now allowed ~3,000 output tokens instead of 768, so
at ~40 tok/s it holds the panel for about 75 seconds instead of 19. That is
what rewriting two pages locally actually costs, and it streams, so the user
watches it happen.

**When the refusal does fire:** dense text where a character is nearly a token
— CJK, code, base64. An 8,000-character CJK selection is ~6,000 prompt tokens,
the context term binds, and the user gets *"That passage is too long for this
model to rewrite in one piece. Nothing was changed — select a shorter passage
and try again."* That is a real reduction in capability for that case, and it
is the right one: before, those selections were silently destroyed.

If you want that population served rather than refused, the lever is
`EngineLimits.contextCap` (8,192 is our self-imposed memory cap; the model
reports `max_position_embeddings: 262144`). Raising it doubles KV memory, so I
did not do it unilaterally.

## 4. One line I did not write, and one I did not either

**`ValidationFailure` is untouched, on purpose.** My first design put the
lower-bound check in `RewriteCore.OutputValidator`, which needs a new
`ValidationFailure` case — and `AppCore/ValidationFailure+Message.swift`
switches over it with no `default`, so adding one **breaks the AppCore build
for every other agent**. Moving the check into `Engines` avoids that entirely
and puts it beside the exact signal it backs up.

**`EngineFailure` needs one line from `fix-settings` for the best wording.**
`GenerationError.truncated` currently falls through
`AppCore/EngineFailure.swift` to the generic sentence: *"The rewrite stopped
before it finished. Try again, or pick a different model in Settings."* That is
truthful and the user's text is safe, so nothing is blocked. But the good
sentence already exists as `GenerationError.truncated.message`. The change:

```swift
// EngineFailure.reason(for:) and .state(for:)
if let incomplete = error as? GenerationError { return incomplete.message }
```

Your call whether to relay it; I stayed out of `AppCore`.

## 5. TDD evidence

Baseline before any change: **19 tests, all passing.** After: **28 tests, all
passing**, plus AppCoreTests 45 and RewriteCoreTests 14 unaffected.

### RED → GREEN, three cycles

**Cycle 1 — the budget.** RED:

```
✘ "output budget floors at 64 and scales by 1.4 above it" — EngineLimitsTests.swift:19
  ↳ EngineLimits.outputBudget(inputTokens: 2000) == 2800 → false
  ↳   EngineLimits.outputBudget(inputTokens: 2000) → 768
✘ "the budget can hold a rewrite as long as its input, within the context cap"
  ↳ 1000 input tokens got a 768-token budget: a rewrite would be cut off
  ↳ 2000 input tokens got a 768-token budget: a rewrite would be cut off
  ↳ 3000 input tokens got a 768-token budget: a rewrite would be cut off
  ↳ 4096 input tokens got a 768-token budget: a rewrite would be cut off
✘ Suite "EngineLimits" failed after 0.001 seconds with 5 issues.
```

GREEN: `✔ Test run with 20 tests in 7 suites passed`.

**Cycle 2 — refuse on the stop reason.** The seam change landed first and was
verified behaviour-preserving (`✔ Test run with 20 tests ... passed`), which
also proved the `streamDetails` call type-checks against the real MLX API.
Then RED:

```
✘ "a rewrite the budget cut short is refused, not offered as finished" — MLXEngineTests.swift:174
  ↳ Expectation failed: an error was expected but none was thrown
  ↳ GenerationError.truncated → <not evaluated>
✘ MLXEngineTests.swift:177: events.allSatisfy { if case .finished = $0 { false } else { true } }
  ↳ a truncated rewrite must never reach the replacement path
```

GREEN: `✔ Test run with 21 tests in 7 suites passed`.

**Cycle 3 — the backstop.** RED against a `return false` stub (the two truthy
cases fail, the three fail-open cases correctly already pass):

```
✘ "output that stops mid-sentence, where the source did not, is truncated" — :25
✘ "closing quotes, brackets and trailing whitespace are looked through" — :73
✘ Test run with 26 tests in 8 suites failed after 0.198 seconds with 2 issues.
```

GREEN, then RED again for the wiring into both engines:

```
✘ "output that stops mid-sentence is refused rather than finished" — AppleFoundationEngineTests.swift:120
  ↳ Expectation failed: an error was expected but none was thrown
✘ "output that stops mid-sentence is refused even when the decoder claims it finished" — MLXEngineTests.swift:215
  ↳ Expectation failed: an error was expected but none was thrown
✘ Test run with 28 tests in 8 suites failed after 0.143 seconds with 3 issues.
```

GREEN: `✔ Test run with 28 tests in 8 suites passed`.

### Mutation, on a copy at `/tmp/everest-mut` (now deleted)

Three `OutputCompleteness` tests assert something *does not* happen, so they
passed against the stub and never went RED. That is the case root §0 says
mutation is for. Two mutations, both built and run in the copy, shared tree
never modified.

**Mutation 1 — the length ratio the comment argues against** (`< 0.6`):

```
✘ "a much shorter rewrite that ends properly is not truncated"          ← the anti-ratio guard bites
✘ "output that stops mid-sentence, where the source did not, is truncated"  ← ratio misses a real truncation (0.75)
✘ "token deltas are emitted as cumulative snapshots"            ↳ Caught error: .truncated
✘ "the finished event carries the complete final text"          ↳ Caught error: .truncated
✘ "Apple's snapshots are forwarded unchanged..."                ↳ Caught error: .truncated
```

The collateral is the argument, not noise: a ratio falsely flagged three
ordinary short rewrites as truncated.

**Mutation 2 — remove the fail-open guards**, judging the output without asking
whether the source was a complete sentence:

```
✘ "a source that is itself a fragment never triggers the rule" — :53
✘ "empty output is not this rule's concern" — :85
```

Every test in this change is now proven by an honest RED or by mutation.

### Verification hygiene

Two things bit me and are worth recording. `xcrun xctest -XCTest '<suite>'`
silently matches **nothing** for swift-testing suites and reports
`Executed 0 tests ... passed` — the exact false green root §8 warns about; I
caught it and switched to running the whole bundle. Separately my shell's cwd
was reset mid-session, so one `swift build` ran outside the package; I
re-verified the whole result from scratch with absolute paths (bundle rebuilt
00:15:09, run 00:15:45) and have issued build+test as a single `&&` command
since.

## 6. Two things to know

**Your commit `7334547` ("Fix five Settings and menu-bar defects") contains my
work.** Something ran `git commit -a` while I was mid-cycle and swept in all 12
of my files, including the new `OutputCompleteness.swift` and its tests. I
checked the committed content and it is intact and correct. I did **not**
rewrite history to separate it — with four agents live that would be worse than
the mislabelling. You may want to note it in the log, and to tell whoever is
committing to stage explicitly.

**`Engines/AGENTS.md` was at its 60-line budget**, so documenting this meant
cutting rather than appending. I compressed my own section twice, folded the
build/test preamble into a pointer to root §8, and replaced the four-cache-
locations **table** with a pointer to the identical table already in
`ModelStore.locations(for:)`, keeping its rationale. 57 lines now. Say the word
if you want that table back and I will cut elsewhere.
