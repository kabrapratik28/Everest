# Round 2 — re-audit after the fixes land

Round 1 audited the code as written. Round 2 audits **the fixes and what they
did to each other**. Five agents changed overlapping systems in parallel, which
is where new defects come from, and no single agent can see across them.

Run this **after** all round-1 fixes are committed and the full suite is green.

## Why the delta is the target, not the code

Every round-1 finding was in code that had passed review and had tests. The
fixes have had less scrutiny than the code they replaced and were written
without sight of each other. Re-running the same three audits unchanged would
mostly re-derive what we already fixed.

## Interaction risks predicted in advance

Written before round 2 runs, so the auditors can confirm or refute rather than
rediscover. Being wrong about these is a useful result too.

| Interaction | Why it is risky |
|---|---|
| `fix-model` memoises the engine **and** `fix-settings` changes delete/Model-tab behaviour | Both halves of one invariant, written by two agents who could not see each other. If eviction and deletion disagree, the user frees disk and no memory while availability lies. |
| `fix-keys` adds a consuming `CGEventTap` **and** makes terminal panels key (EVE-010) | Two mechanisms now decide who gets a keystroke. Overlap is a double-handled key; a gap is a key nobody handles. |
| `audit-correctness` refuses over-long input **and** `fix-settings` owns the messages | A refusal with no sentence is a silent failure, which is the worst outcome in this app. |
| Nonce delimiter **and** `clean()` regex | Written by two agents at different times against different delimiter formats. |
| `fix-docs` changes the capture chain **and** `fix-keys` changes when capture happens | Capture ordering relative to the picker is a data-loss guard. |
| Engine memoisation **and** cancellation/supersede | A retained engine outlives the transaction that created it. `cancel()` semantics were written for a per-transaction engine. |

## Scope for each round-2 auditor

1. **Regression auditor.** Diff `3954ef1..HEAD`. For each fix: does it do what its
   commit claims, and what did it break? Specifically hunt for guards weakened to
   make a test pass.
2. **Interaction auditor.** The table above plus anything else crossing two
   agents' targets. This one cannot be done by any agent that wrote a fix.
3. **Test-quality auditor.** ~220 tests now. Which cannot fail? Which duplicate
   another's root cause (§1)? Which assert on a mock rather than behaviour? The
   injection escape survived behind a test whose payload contained no delimiter —
   assume there are more of those.

## Rules

- **Read-only.** Findings only; fixes are dispatched afterwards, as in round 1.
- Rank by severity, data loss first.
- Say **"traced"** versus **"could not rule out"** explicitly. Round 1's value
  came from that distinction being honest.
- Do not re-report anything already in `PUNCH-LIST.md` or fixed in round 1.
- A short report of real findings beats a long one of maybes.
