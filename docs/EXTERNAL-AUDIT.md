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
| EVE-004 | P1 | Preparation is not cancellable | In progress |
| EVE-005 | P1 | `LoadedModel` admits duplicate concurrent loads | **Fixed** — `LoadOnce` caches the in-flight `Task`, not just the result (`00614ae`) |
| EVE-006 | P1 | Onboarding cannot download the default model | In progress |
| EVE-007 | P1 | Shortcut labels hardcoded, contradict the default | In progress |
| EVE-008 | P1 | 30B offered on Macs that cannot run it | In progress |
| EVE-009 | P1 | Posted ⌘C/⌘V can fire after their timeout | **Fixed** — copy half `302ff94`, paste half `943da4f` (restore only after the full budget) |
| EVE-010 | P1 | Panel ⌘C not consumed, source app overwrites it | **Fixed** — `makeKey()` on terminal states; a non-activating panel can hold key without activating (`f941a5f`) |
| EVE-011 | P2 | Google Docs rejected before clipboard fallback | **Fixed** (`fb76aa9`) |
| EVE-012 | P2 | `clean()` corrupts legitimate content | **Fixed** — unwrap only the id-carrying envelope, quotes only if the source was unquoted (`56f671b`); 3× ratio removed (`79dcb62`) |
| EVE-013 | P2 | Onboarding keyed to permission, not completion | In progress |
| EVE-014 | P2 | Model-management failures swallowed | In progress |
| EVE-015 | P2 | Unusable style/privacy states | Partly fixed (blank names refused); rest in progress |
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
