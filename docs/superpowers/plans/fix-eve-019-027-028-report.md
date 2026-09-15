# EVE-019, EVE-027, EVE-028

Verified all three against the code first. **All three hold.** EVE-019 and
EVE-027 are fixed; EVE-028 is recorded, not built, as asked.

**Three commits' worth**, separable:

| | Files |
|---|---|
| **EVE-019** (P0) | `RewriteCore/OutputValidator.swift`, `Tests/RewriteCoreTests/CoreTests.swift`, `RewriteCore/AGENTS.md` |
| **EVE-027** (P2) | `Engines/MLXEngine.swift`, `Tests/EnginesTests/MLXEngineTests.swift`, `Tests/EnginesTests/ScriptedTokenProducer.swift`, `Engines/AGENTS.md` |
| **EVE-028** (P2) | `Engines/EngineLimits.swift` — comment only, no behaviour change |

21 / 33 / 75 / 79 / 76 green. Both `AGENTS.md` under budget (59, 58), edited
in place.

---

## EVE-019 — I do not need to thread the ID, and this is cheaper *and* more exact

**You asked me to reconsider threading, and I want to be clear I am not
re-running the old cost argument.** The auditor's reframing is correct and it
does change the severity: it was never a 2⁻⁶⁴ collision, because the cleaner
accepted *any* well-formed id. With auto-replace on, that is silent data loss.

But threading is not the cheapest exact fix, and I had missed the obvious one.
**`clean` already takes `source`.** Every other rule in that function already
consults it — the quote rule was built on exactly this comparison — and the
envelope rule was the single rule that did not.

```swift
// Theirs, not ours.
guard !source.contains(text[opening.range]) else { return nil }
```

Our id is drawn fresh per prompt, so a selection the user made *beforehand*
cannot contain it — unless they typed that tag themselves, which is precisely
the case to leave alone. That gets the real 2⁻⁶⁴ back:

| Case | Before | Now |
|---|---|---|
| Model echoes our envelope | unwrapped | unwrapped (id is fresh, absent from source) |
| User's text holds a 16-hex pair | **destroyed** | untouched |
| User's text holds *our* fresh random id | destroyed | 2⁻⁶⁴ |

So the exactness threading would buy is already bought, for two lines, with
nothing carried through `PromptBuilder` → two engines → `validate`. If you
still want the real id threaded I will do it, but it now buys only the 2⁻⁶⁴
case.

**RED** — the payload is copied out of our own test file, which is the point:

```
✘ "OutputValidator.clean keeps an envelope-shaped pair the user wrote themselves"
↳ OutputValidator.clean(text, source: text) → "inner"
↳ text → "Keep this. <selected_text_3f2a19bb7c0d4e51>inner</selected_text_3f2a19bb7c0d4e51> And this."
```

### Second half: the trim

Correct, and it is my own argument one function along. `PromptBuilder` puts
the text on its own line, so there is **exactly one** newline inside each tag
and those two are ours. `trimmingCharacters(in: .whitespacesAndNewlines)` took
everything else with them.

**RED:**

```
✘ "OutputValidator.clean strips the envelope's own newlines and no other whitespace"
↳ cleaned → "let x = 1"          (expected "    let x = 1")
```

Now drops one leading and one trailing newline and nothing else.

## EVE-027 — the heuristic no longer overrides an exact answer

Right, and it contradicted the reason I read `stopReason` in the first place.
Running the punctuation check over a reported `.endOfText` can only produce
**false refusals**, because a real truncation reports `.budgetExhausted` and
is caught a line earlier. It cost every valid rewrite ending in a colon or a
list item whose source happened to end as a sentence.

It now runs only when the producer reports **nothing** — the dependency-
regression case it was actually added for.

**Two REDs, because the second test could not fail against the first fix.**
Rather than mutate, I sequenced it so both were observed:

*Step 1 — heuristic still unconditional:*
```
✘ "a rewrite the decoder reports complete is not re-judged from its punctuation"
  MLXEngineTests.swift:204:6: Caught error: .truncated
```

*Step 2 — heuristic deleted outright:*
```
✘ "a producer that reports no stop reason has its output checked instead"
  MLXEngineTests.swift:238:15: an error was expected but none was thrown
```

*Step 3 — gated on `stop == nil`:* both pass. One mutation at a time, per §0 —
in fact none, since step 2 is an honest intermediate rather than a mutation.

`ScriptedTokenProducer.stop` is now `GenerationStop?` so a test can script a
producer that reports nothing at all.

**The inverse on Apple is unfixable as things stand.** A partial rewrite that
happens to stop after an early full stop is accepted there, and can replace
the whole source. `FoundationModels` exposes no completion reason and no token
count, so there is no signal to distinguish it from a short correct rewrite —
punctuation is all there is, and punctuation says "finished". The only real
mitigations are not using Apple's engine for long selections, or Apple
shipping a stop reason.

## EVE-028 — recorded, not built

Real, and it gets **worse with length**, which the filing understates. The
prompt's fixed overhead shrinks as a share of the budget, so the effective
ceiling on an `Expand` tightens as the selection grows:

| Selection | Effective ceiling |
|---|---|
| 500 chars | ~3.0× |
| 1,000 | ~2.2× |
| 2,000 | ~1.8× |
| 4,000 | ~1.6× |

**A per-preset multiplier cannot work**, for exactly the reason that retired
the 3× ratio: intent is not in the length, and the only thing carrying intent
is `preset.instruction`, which the user edits freely. Building that knob would
be building the thing we just removed, one layer down.

**But this is materially less serious than the ratio was, and that difference
is the recommendation.** The ratio refused `Expand` *and* blamed the model
("far more text than it was given"). This refuses visibly, with the user's
text untouched and a sentence telling them to select a shorter passage. It is
a capability limit, not a correctness defect.

The one real lever is raising `outputScale` globally, which buys `Expand` room
at the cost of letting a rambling generation run longer before producing the
same refusal. That is a product call, so I have not taken it.

**I did change one thing:** the constant's own doc comment claimed a rewrite
"essentially never" runs longer than 1.4× — which is **false about a preset
that ships in the app**. That is the same failure as the "by construction"
comment: a justification that stops the next person checking. The comment now
states the real ceilings, why a per-preset knob cannot work, and that raising
it is a product call. No behaviour change.
