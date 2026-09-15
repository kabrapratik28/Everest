# EVE-032 (P0) — the two cleaners without provenance

**Test counts after:** RewriteCore **20**, Engines **33**, AppCore **78**,
TextBridge **84**, Overlay **77**. All green.

RewriteCore went 21 → 23 (two RED tests added) → 20 (three obsolete tests
deleted). No new files.

**Decision: I removed both rules rather than making them source-aware.** You
said you would take deletion unless I could name the case that needs it. I
could not name one for the preamble, and I found a *worse* failure in the
quote rule than the one filed, which settles that half.

| File | Change |
|---|---|
| `RewriteCore/OutputValidator.swift` | preamble strip and quote strip deleted; `clean` is the envelope unwrap alone |
| `Tests/RewriteCoreTests/CoreTests.swift` | 2 tests added, 3 deleted |
| `RewriteCore/AGENTS.md` | rewritten `clean` paragraph, 59 lines |
| ⚠️ `Tests/AppCoreTests/RewriteCoordinatorTests.swift` | **not my target** — payload swap, see below |
| ⚠️ `Tests/AppCoreTests/SettingsModelTests.swift` | **not my target** — payload swap, see below |

---

## RED

```
✘ Test "OutputValidator.clean leaves a conversational preamble the user selected"
  recorded an issue at CoreTests.swift:118:5:
  Expectation failed: OutputValidator.clean(text, source: text) == text
↳ OutputValidator.clean(text, source: text) → "The phrase this app used to delete."

✘ Test "OutputValidator.clean leaves quotation marks alone"
  recorded an issue at CoreTests.swift:139:5:
↳ OutputValidator.clean(quotedWithNewline, source: "\"Hello\"\n") → "Hello there"

✘ Test "OutputValidator.clean leaves quotation marks alone"
  recorded an issue at CoreTests.swift:142:5:
↳ OutputValidator.clean(dialogue, source: "he said hello and she said goodbye")
  → "Hello," he said, and she replied, "Goodbye."

✘ Test run with 23 tests in 0 suites failed after 0.009 seconds with 3 issues.
```

## The preamble: deleted, and I could not name the case

`OutputValidator.swift:24-27` held **one literal**,
`"Sure! Here's an improved version:\n\n"`, stripped by prefix match with no
reference to the source. It never fired on "Here's the improved version:", or
"Certainly!", or any other phrasing — it was one sample of an unbounded set.
So the trade was a single string's worth of tidiness against deterministically
deleting that sentence from anyone who selected it, and `safetyFrame` already
asks for no preface.

Source-awareness was available and I did not take it, because it would have
preserved a rule that buys almost nothing while keeping a branch that has to
stay correct. Deleted.

## The quotes: worse than filed, and unrepairable

Your read was that `"Hello"\n` being treated as unquoted is the bug and that
fixing the comparison would be a second heuristic on the first. Both true. But
there is a case that no comparison fixes, and it is the third assertion above:

```
source:  he said hello and she said goodbye        ← not quoted
output:  "Hello," he said, and she replied, "Goodbye."
result:   Hello," he said, and she replied, "Goodbye.
```

A rewrite that legitimately *opens and closes* on a quotation mark is
indistinguishable from one the model wrapped, and the source is no help
because the source is not quoted either. `unquoted` drops the first and last
character, so the output comes back **unbalanced** — worse than either keeping
or removing the pair, and reachable today by rewriting any sentence into
dialogue. That is not in the audit; I found it writing the regression test.

So the rule cannot be made source-aware, only deleted. Done.

`clean` is now the envelope unwrap and nothing else — the one rule tied to an
exact per-request structure, exactly as the auditor proposed.

## GREEN

```
RewriteCoreTests   ✔ Test run with 20 tests in 0 suites passed after 0.004 seconds.
EnginesTests       ✔ Test run with 33 tests in 9 suites passed after 0.188 seconds.
AppCoreTests       ✔ Test run with 78 tests in 1 suite passed after 0.076 seconds.
TextBridgeTests    ✔ Test run with 84 tests in 10 suites passed after 1.213 seconds.
OverlayTests       ✔ Test run with 77 tests in 11 suites passed after 0.095 seconds.
```

## ⚠️ Two files I edited outside my target

Deleting the preamble strip broke two `AppCoreTests` tests that used it as
their payload:

- `RewriteCoordinatorTests.swift:95` — *"finished is not the end: the cleaned
  output is applied"*
- `SettingsModelTests.swift:283` — *"the test box rewrites its sample through
  the selected engine and validates the result"*

Neither is *about* preambles. Both use one only to make "cleaned ≠ raw"
observable, so I swapped the payload for an echoed envelope — the one thing
`clean` still removes — and left the assertions and the intent untouched.

**Both files were clean in `git status` when I edited them**, so I have not
merged over anyone. I did it rather than leaving `AppCoreTests` red, on the
precedent that a red shared suite misleads everybody; but it is `fix-settings`'
target and they should know. If they would rather own the change, it is two
string literals and I will revert mine.

## Process slip, recorded

Removing the two rules by script, I sliced a region backwards and **duplicated
`unwrappedEnvelope` instead of deleting the quote helpers**. The compiler
caught it (`invalid redeclaration`), nothing shipped, and I rebuilt the file
from its two good halves. The lesson is narrow and I have taken it: I was
scripting multi-region deletions on a file small enough to edit by hand and
already open in front of me, and the script's index arithmetic was the only
part nobody checked.
