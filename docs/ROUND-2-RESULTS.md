# Round 2 — what the re-audit found

Three read-only auditors over the ~50 commits of round 1. The plan and the
predicted interactions are in `ROUND-2-PLAN.md`; this is the outcome.

**The premise held.** Every round-1 fix had tests, a report, and an owner who
believed it worked. Round 2 found eight further defects, **three of them
introduced by round-1 fixes** and two of them in code committed hours earlier
as the fix for the previous instance of the same bug.

## Findings and disposition

| # | Finding | Severity | State |
|---|---|---|---|
| F1 | `OutputValidator`'s envelope regex matched **any** hex run, so `<selected_text_1>` in the user's own text made `clean` return only what was between the tags | **Data loss** | Fixed — `{16}` plus the close found by the open's own id |
| R2 | `handle()` read `state` *after* `perform`; production's `onCopy` dismisses synchronously, so ⌘C reported "not consumed" and the app underneath overwrote the rewrite | **Data loss** | Fixed — decide from the dispatched-against state |
| F2 | `run` samples the generation *after* an unguarded suspension, so a superseded transaction adopts the superseding token and passes every guard | **Data loss** | **Open** — being fixed by binding the token at `begin()` |
| T1 | The rung-8 secure-field re-check has **no test**: delete it and all 74 TextBridge tests pass, while it is the only guard on the Chromium password path | **Untested guard** | In progress |
| F3/F5 | A spent picker kept acting on keys while no longer consuming them, reopening EVE-002 for one actor hop — after Escape, after a pick, and after an unclaimed key | Data loss, narrow | Fixed — inert rather than unarmed |
| T2 | The 8,000-character refusal was pinned to rung 5; nothing drove it through rungs 7 or 9, the whole copy-only column | Untested guard | In progress |
| T3 | `pending = nil` can be deleted with all 61 AppCore tests passing — a wrong-target write, since `pickStyle` has no generation guard | Untested guard | Folded into F2 |
| F4 | A hotkey press silently reset the Settings test box to its placeholder | Silent failure | Fixed |
| R5 | `EngineFailure.state(for:)` lacked a branch `reason(for:)` had, so the panel showed a generic sentence | Wrong message | Fixed structurally — `state` now derives from `reason` |

Plus three redundant tests to delete, one conditionally vacuous test, two
unpinned resets, and one stale comment inviting someone to "fix" a correct
guard. Six joins that could not be settled by reading are manual checks 22-27.

## What the audits confirmed rather than found

Worth as much as the findings, and each retires a worry:

- **All eleven root §6 guards intact and reachable**, verified individually,
  and all 200 removed production lines diffed looking for a loosened one.
- **The pasteboard borrow cannot be held across two transactions** — every
  acquire/release pair sits inside one synchronous main-actor body.
- **Four of the six predicted interactions refuted**, including that engine
  eviction and availability could disagree.
- **No commit message claimed work that was absent**, and no guard was
  weakened to make a test pass.
- **The `SpyKeyMonitor` vacuity trap does not generalise** — no other target
  has a double with a nil-able handler.

## The pattern worth keeping

**A confident doc is a place defects hide.** Three of the eight sat behind
prose asserting they could not happen: `OutputValidator`'s comment claimed the
id made the match safe "by construction"; `TextBridge/AGENTS.md` presented the
copy budget as a closed class; a test comment said whitespace "would be
written" when the validator rejects it. In each case the code was wrong and the
prose is why nobody checked.

**And a test whose payload cannot reach the code proves nothing.** F1 was the
third defect in one function to survive that way — the guarding test used a
bare `<selected_text>`, which no version of the pattern could match. Both rules
are now in root §1 next to the positive-control requirement.
