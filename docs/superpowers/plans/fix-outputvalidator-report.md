# Fix: EVE-012 — `OutputValidator.clean` corrupting legitimate content

**One commit.** Files:

| File | Change |
|---|---|
| `EverestKit/Sources/RewriteCore/OutputValidator.swift` | envelope + quote rules now compare against the source |
| `EverestKit/Tests/RewriteCoreTests/CoreTests.swift` | 3 tests reworked, 2 added |
| `EverestKit/Sources/RewriteCore/AGENTS.md` | records *why* (57 lines, under budget) |

`PromptBuilder.swift` **not** touched. No other module touched — `clean` is
called only from `validate` and its tests, so widening its signature stayed
contained.

---

## Three defects, one shape

All three are the same mistake: **`clean` could not tell the model's packaging
from the user's content, because it never looked at the source.**

1. **Every `<selected_text>` occurrence was deleted, anywhere in the output.**
   Rewrite a sentence of documentation that mentions the tag and it vanishes
   from your own text.
2. **Any outer pair of double quotes was stripped.** The safety frame
   explicitly instructs the model to preserve quotation marks, and then we
   removed them. Worse than losing them: a source holding two quoted phrases
   came back **unbalanced** — `"A" and "B"` → `A" and "B`.
3. **The literal tag no longer matches anything.** `audit-security`'s nonce
   landed under this code, so the model is now shown
   `<selected_text_<16 hex>>` and `clean` was still stripping the bare form.

## The fix

**Envelope:** unwrapped only around the **whole** output, and only when it
carries a per-prompt id. The second constraint fell out of the nonce and is
the stronger of the two — *the model is never shown a bare tag, so a bare tag
in the output can only have come from the user.* Matched as a pattern
(`<selected_text_[0-9a-fA-F]+>`) rather than threaded from `PromptBuilder`
through both engines into `validate`: four files across three modules for an
occasional cosmetic tic, and containment is structural anyway. Your call,
taken as given.

**Quotes:** removed only when the source was *not* quoted too. That is the
question that separates "the model wrapped its reply" from "the user is
quoting someone".

The captured envelope content is trimmed of surrounding whitespace, because
`PromptBuilder` puts the text on its own line — those newlines are the
envelope, not the rewrite.

One compiler finding on the way: `Regex` is not `Sendable`, so the pattern
cannot be a `static let` under Swift 6. It is a computed property, built once
per rewrite rather than per token.

## RED

Three failures, three distinct causes — not one bug wearing three hats:

```
✘ "OutputValidator.clean unwraps an echoed envelope carrying its per-prompt id"
  CoreTests.swift:31:5: Expectation failed: cleaned == "This is the rewritten text."
✘ "OutputValidator.clean leaves selected_text tags that are the user's own text"
  CoreTests.swift:47:5: Expectation failed: cleaned == raw
✘ "OutputValidator.clean keeps quotes when the source was quoted too"
  CoreTests.swift:61:5: Expectation failed: cleaned == raw
✘ Test run with 16 tests in 0 suites failed after 0.006 seconds with 3 issues.
```

**You were right that the old test would not catch this.** The existing
"strips stray selected_text wrapper tags" test fed `clean` the bare tag
directly, so it passed against code that no longer matched anything the model
is shown. It is replaced by the nonce'd version rather than kept alongside —
same behaviour, and two tests failing for one cause is one too many.

And the point you asked me to carry over from `audit-security` holds here
exactly: **the legitimate-text tests were the ones that failed.** The old
`clean` did not merely miss the artefact it was aiming at, it damaged correct
input — the same bug class, in the same function, found the same way.

## GREEN

```
✔ Test run with 16 tests in 0 suites passed after 0.007 seconds.
```

Every target, after all three of my fixes:

```
RewriteCoreTests   ✔ 16 tests passed
EnginesTests       ✔ 32 tests passed
AppCoreTests       ✔ 56 tests passed
TextBridgeTests    ✔ 72 tests passed
OverlayTests       ✔ 68 tests passed
```

## Residual, stated rather than hidden

If a user's entire selection is *exactly* `<selected_text_deadbeef…>text</…>`
and the rewrite returns the same shape, it will still be unwrapped. Requiring
the nonce makes this vanishingly unlikely, and the whole-output constraint
makes it narrower again. Catching it needs the real id threaded through, which
is the expensive fix you scoped out.

---

# The 3× rule and the "Expand" preset — analysis, **not landed**

You asked me to reach a conclusion rather than tune a threshold. Here it is.

## A ratio cannot carry this

`Expand` is a **built-in** style: *"Expand this with more supporting detail and
clarity while preserving the original meaning."* On a 29-character sentence a
genuine expansion is 200–400 characters — 7× to 14×. The validator rejects
everything over 3×, so **Expand is refused every time on short input**, which
is the input people expand. It works only on long sources, where nobody needs
it. This has been true since the rule was written.

That is the mirror of the lower bound I declined earlier, and the root is the
same: **the ratio is being asked to infer intent, and intent is not in the
length.** The only thing encoding intent is `preset.instruction`, which is free
text the user can edit — so there is no reliable mapping from it to an expected
ratio, and a user who types "expand this into three paragraphs" into *Quick
Improve* defeats any per-preset factor you declare.

## The guard's two stated jobs are now done elsewhere

- **"Runaway generation."** Structurally impossible now. The decoder stops at
  `maxOutputTokens`, and after the truncation fix a generation that hits that
  stop is refused outright as `GenerationError.truncated`. **A runaway
  generation *is* a budget-exhausted generation**, and it is caught exactly,
  at the decoder, by its own stop reason.
- **"A hijacked response."** `RewriteCore/AGENTS.md` already concedes the ratio
  "catches runaway generation, not a short plausible-looking hijack", and
  containment is structural in `PromptBuilder`.

What is left is one narrow band: a hijack that stops cleanly at, say, 5× on a
short source. The ratio catches that. **But that band is precisely the band
Expand must work in** — same source lengths, same multiples. You cannot keep
one without losing the other, and no threshold separates them, because the
difference between them is not the length.

## Recommendation

Remove `maxLengthRatio` and `ValidationFailure.lengthRatio`; keep `.empty`. The
upper bound belongs on the decoder, where it is enforceable and already exists,
not in the validator where it has to guess.

**I did not land it**, for two reasons. It is a product-risk call that is
yours: today a long hijack leaves the user's text alone and shows a sentence,
and after removal it would replace the selection (visible, and undoable in the
target app, but replaced). And it is **not purely in my scope** — deleting the
enum case breaks `AppCore/ValidationFailure+Message.swift`, whose switch has no
`default`, which is `fix-settings`' file.

Say the word and it is about twenty minutes including the RED.

If you would rather keep a bound, the only honest version is a growth factor
declared on `Preset` — but that means a new stored property on a Codable type
persisted in `UserDefaults` (migration), a Settings control for it, and it is
*still* only a hint the user can contradict in the instruction text. I would
not do that to preserve a guard whose remaining job is this narrow.
