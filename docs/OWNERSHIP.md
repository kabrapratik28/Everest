# Who owns what, right now

**Operational state, not architecture.** Stale the moment work finishes — check
the date, and ask the lead rather than trusting a name you remember.

Last updated: 2026-09-15 01:20 PDT

| Target | Owner | Notes |
|---|---|---|
| `EverestKit/Sources/TextBridge/` + tests | **fix-docs** | Was `tdd-bridge`. Reassigned without telling it, which caused three misroutes. |
| `EverestKit/Sources/Engines/` + tests | **audit-correctness** | Truncation fix. Was `tdd-engines`. |
| `EverestKit/Sources/RewriteCore/OutputValidator.swift`, `EngineLimits.swift` | **audit-correctness** | |
| `EverestKit/Sources/RewriteCore/PromptBuilder.swift` | *unowned* | `audit-security` finished and stood down. |
| `EverestKit/Sources/Overlay/` + tests | **fix-keys** | Was `tdd-overlay`. |
| `EverestKit/Sources/AppCore/` + tests | **fix-settings** | `EngineFactory.swift` was carved out to `fix-model`, now finished and returned. |
| `Everest/App/`, `Everest/Settings/` | **fix-settings** | Except `HotkeyManager.swift`, which is the lead's. |
| `project.yml`, `README.md`, root `AGENTS.md`, `docs/` | **lead** | |
| git — every command | **lead only** | Six agents, one tree. A stray `checkout` destroys uncommitted work. |

## Why this file exists

An agent stood down, its target was reassigned, and nobody told it. Three
separate changes were then attributed to it, and it had to read the tree each
time to find out what had actually happened.

The cost is not the wasted minutes. On the third one it was asked to fix an
assertion that was **already fixed, and fixed better** — had it complied it
would have replaced a case-addressed assertion with a fragile index-addressed
one, in a target it did not own, and made things worse while looking
responsive. What caught it was the agent being suspicious enough to check
first, and suspicion is not a mechanism.

## Rules

- **Commit by explicit pathspec, never `git add -A`.** Six agents write to one
  tree, so a blanket add stages whatever three of them happened to have on
  disk. `7334547` was titled for five Settings defects and in fact carried the
  picker event tap and the Engines truncation work as well — two fixes with no
  commit of their own and no message describing them. Stage the files the
  commit is about and check `git status` afterwards for what you left behind.
- **Reassigning a target means telling the outgoing owner.** Silence leaves
  them nominally responsible for work they cannot answer for.
- **Route by this table, not by the last owner you remember.**
- **Verify before you act on a report about your own files.** Reports go stale
  fast here; so do the lead's. Two of the lead's own bug reports were of
  problems already fixed.
