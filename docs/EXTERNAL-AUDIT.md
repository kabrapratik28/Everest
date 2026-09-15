# External audit — what came of it

A second AI read the tree at commit `3954ef1` and filed EVE-001…018. Source:
`08-AI-rewrite-app/01-Manual Code Audit.md` in the Obsidian vault. This file
tracks disposition only; the reasoning behind each fix is in the owning
directory's `AGENTS.md` and the agent reports under `docs/superpowers/plans/`.

**Its method was sound and worth copying.** It pinned a stable commit, read
production Swift and tests without building, listed the dirty worktree
separately rather than crediting it, and refused to report intentional
behaviour (copy-only terminals, optional Apple Foundation Models, the Qwen3.5
exclusion) as defects. Both of its P0s were the two we had independently
ranked highest.

## Status

| ID | Sev | What | Status |
|---|---|---|---|
| EVE-001 | P0 | Truncated generation replaces the selection | **Fixed** — decoder stop reason, budget `contextCap - inputTokens`, completeness backstop |
| EVE-002 | P0 | Picker keys edit the source document | **Fixed** — consuming `CGEventTap`, measured against a live TextEdit |
| EVE-003 | P1 | Engine reloads 2.3 GB per rewrite | **Fixed** — `EngineRegistry` memoises one per `EngineID`, evicts on delete (`2c94d16`) |
| EVE-004 | P1 | Preparation is not cancellable | **Fixed** — the `prepare` task is stored and cancelled, and progress is generation-checked before touching the panel |
| EVE-005 | P1 | `LoadedModel` admits duplicate concurrent loads | **Fixed** — `LoadOnce` caches the in-flight `Task`, not just the result (`00614ae`) |
| EVE-006 | P1 | Onboarding cannot download the default model | **Fixed** — selection and install state are separate facts on a row |
| EVE-007 | P1 | Shortcut labels hardcoded, contradict the default | **Fixed** — `ShortcutCopy` renders from the live binding; no glyph is written down |
| EVE-008 | P1 | 30B offered on Macs that cannot run it | **Fixed** — `fitsInMemory` gates ahead of both selection and install |
| EVE-009 | P1 | Posted ⌘C/⌘V can fire after their timeout | **Fixed** — copy half `302ff94`, paste half `943da4f` (restore only after the full budget) |
| EVE-010 | P1 | Panel ⌘C not consumed, source app overwrites it | **Fixed** — `makeKey()` on terminal states; a non-activating panel can hold key without activating (`f941a5f`) |
| EVE-011 | P2 | Google Docs rejected before clipboard fallback | **Fixed** (`fb76aa9`) |
| EVE-012 | P2 | `clean()` corrupts legitimate content | **Fixed** — `56f671b` + **`6b0eea9`**, which repairs a greedy-match wrong-write in `56f671b` itself; 3× ratio removed (`79dcb62`) |
| EVE-013 | P2 | Onboarding keyed to permission, not completion | **Fixed** — completion and current step both persisted |
| EVE-014 | P2 | Model-management failures swallowed | **Fixed** — `download` records rather than throws, since the error's only consumer is a label |
| EVE-015 | P2 | Unusable style/privacy states | **Mostly** — blank names refused, exclusions removable and validated. **Open:** deleting every style still shows an empty picker (see below) |
| EVE-016 | P2 | AX per-app fallback skips the PID ownership check | **Fixed** (`a704b56`) — and the audit understated it; that branch is the common one on macOS 26 |
| EVE-017 | P2 | Prompt delimiter forgeable | **Fixed** — per-prompt 64-bit id in the tag name (`b52e822`) |
| EVE-018 | P3 | Clean checkout is machine-specific | Partly — README and `Package.resolved` fixed (`f8fc86d`); signing cert is a deliberate open question |

## Where it was right and we would not have got there

**It predicted the exact trap in work that was still uncommitted.** On the
style-picker tap it wrote: *"Reusing `FloatingPanelController.handle`
unchanged still returns `false` because `.stylePicker.acceptsKeyWindow` is
false."* That is precisely the bug a naive tap would have shipped with, and it
was called from a read of unfinished code. `fix-keys` split the two paths —
`handle` returns `acted && acceptsKeyWindow` for the monitors, `intercept`
returns `acted` for the tap — so the monitor contract tests still pass
unchanged. The prediction and the fix are independent and they agree.

**Its EVE-003 caveat was also right**: a per-ID registry can retain 4B *and*
17.2 GB at once. Eviction is pull-based on `installedSnapshot != nil`.

**EVE-012 was understated.** Filed as `clean()` stripping tags too broadly,
which is true. What it could not see is that `b52e822` then changed the
delimiter to carry a per-prompt random id while `clean()` went on stripping the
old literal `<selected_text>`. The two stopped matching, so the unwrap was dead
— a model echoing its wrapper would write `<selected_text_3f9a…>` into the
document, and the only surviving effect of that code was deleting the tag from
content a user legitimately wrote. It had lost its purpose and kept its damage.
Two correct fixes, landed separately in one pipeline, made a third bug. Fixed
in `56f671b`; the rule it produced is in `RewriteCore/AGENTS.md`.

## Still open

**EVE-015's empty picker.** Nothing stops a user deleting every style, and
`chooseStyle` then shows `.stylePicker(presets: [])` — a panel listing nothing.
Largely defused by an unrelated fix: `fix-keys`' rule that any key the picker
cannot answer ends the picker means the first keystroke now dismisses it, where
the audit found only Escape worked. Still wrong to show, and the fix belongs
where the delete happens rather than at the picker.

**EVE-018's certificate**, deliberately — see below.

Everything else on the list is fixed. Statuses above were re-checked against
the code rather than taken from the agent reports, which is how EVE-004 turned
out to be done and EVE-015 turned out not to be.

## Where we diverged

**EVE-007 called the shortcut change "an unapproved product decision."** Fair.
`⌘I` was the requested default and it was changed without asking, because a
global hotkey outranks the frontmost app and Everest was taking Italic from
every editor system-wide. Logged in `QUESTIONS-FOR-PRATIK.md` to be overruled,
not defended.

**EVE-009's paste half overturns a trade this project had made on purpose.**
The clipboard was restored as soon as a paste looked consumed. A slow target
then ran our ⌘V *after* the restore and pasted the user's old clipboard into
their document — silently, automatically, unrecoverably. The fix is to restore
only after the full consumption budget, costing up to ~450 ms during which a
manual ⌘V would yield the rewrite instead. That second failure is visible, the
user caused it, and copying again fixes it. Silent wrong writes outrank
everything else here; the same reasoning bought a 75-second panel hold in
EVE-001.

**EVE-018's signing certificate is deliberate, not debt.** Accessibility
permission is bound to the code signature, so an ad-hoc signature makes the
user re-grant on every rebuild. The hardcoded SHA-1 is what stops that. It does
block a clean checkout on another Mac, which is a real cost and is on the
punch list — but it is a trade, not an oversight.

---

# Re-audit, 2026-09-15 — EVE-019…029

Same auditor, same method, reading the tree after round 2 and the five items
Pratik reported from using the app. It restatused the original eighteen and
filed eleven new findings.

**It earned its keep twice over, and one of its own restatuses was wrong in a
way worth keeping.** It marked **EVE-010 "Fixed"** — *"terminal result panels
now call `makeKey()`"* — in the same document where Pratik was reporting that
⌘V no longer worked. That fix was the cause. A reader of the code and a user
of the app disagreed, and the user was right.

## Status

| ID | Sev | What | State |
|---|---|---|---|
| EVE-019 | P0 | `clean` unwrapped **any** well-formed 16-hex envelope, so a user's own tag pair silently discarded the text around it — and auto-replace writes it | **Fixed.** `clean` already took `source`; if the tag is already there it is the user's. Two lines, not the threading I asked for |
| EVE-020 | P1 | The event tap fails open: on `tapCreate` failure the picker still *acted* on keys it could not consume | **Fixed.** `isActive` asks the tap, which covers `.tapDisabledByUserInput` with no second branch |
| EVE-021 | P1 | The registry can hold 4B and 30B at once, defeating the memory gate | In progress |
| EVE-022 | P1 | Preparation neither single-flight nor cancellable without progress | In progress |
| EVE-023 | P1 | Model eligibility enforced only by views; a persisted 30B bypasses the disabled row | In progress |
| EVE-024 | P1 | Pasteboard write results discarded; the manual Copy button dismisses regardless | **Disputed in part** — see below. The severe half is being fixed differently |
| EVE-025 | P1 | Copy/paste observation confuses other writers with our own event | **Part fixed** (the fallback no longer overwrites a newer clipboard); the rest documented as unfixable |
| EVE-026 | P2 | A `.clipboard` cache entry was self-sustaining after AX recovered | **Fixed.** Consulted only while the app is still dark |
| EVE-027 | P2 | The punctuation heuristic overrode an explicit `.endOfText` | **Fixed.** Runs only when the producer reports nothing |
| EVE-028 | P2 | One output ceiling for every preset; `Expand` hits it | **Recorded, not built** — and worse than filed |
| EVE-029 | P1 | `⌥R`/`⌥⇧R` globally take `®` and `‰` | **Pratik's decision**, made with that cost shown |

## Where we did not do what it asked

**EVE-024's Bool checks.** The audit said to check what `writeObjects` returns.
`fix-docs` could not construct a state where it is `false` — five attempts, all
`true` — and the one documented failure *throws* instead, so a Bool check would
not catch it. Building it would add branches no test can enter, in the
highest-risk file. The severe half is real and the remedy is different:
**do not dismiss `heldForManualCopy` until a read-back proves the text is on
the clipboard.** That catches a silent no-op, an immediate overwrite, and the
throw case.

**EVE-028's per-preset budget.** The ceiling tightens with length — `Expand` is
capped near 3.0× at 500 characters and 1.6× at 4,000. A per-preset multiplier
fails for the reason that retired the 3× ratio: intent is not in the length,
and the only thing carrying it is free text the user edits. The one real lever
is the global `outputScale`, which costs time and memory on every rewrite to
make one preset reliable — a product call, left open.

## The lesson this round produced

**A fix that removes a wrong answer can hand the next stage a right of way it
never had.** Before the leaked-borrow fix, `handOff` could not acquire the
clipboard and the user's fresh copy survived behind a false "another rewrite is
using the clipboard". Fixing the leak was right, and it converted a wrong
*message* into data *loss*. Recorded in `TextBridge/AGENTS.md`.
