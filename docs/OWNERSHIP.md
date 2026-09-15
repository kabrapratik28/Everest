# Who owns what, right now

**Operational state, not architecture.** Stale the moment work finishes — check
the date, and ask the lead rather than trusting a name you remember.

Last updated: 2026-09-15 00:45 PDT

| Target | Owner | Notes |
|---|---|---|
| `EverestKit/Sources/TextBridge/` + tests | **fix-docs** | Was `tdd-bridge`. Reassigned without telling it, which caused three misroutes. Building the EVE-009 paste fix. |
| `EverestKit/Sources/Engines/` + tests | **audit-correctness** | Truncation and `LoadOnce` both landed. Was `tdd-engines`. |
| `EverestKit/Sources/RewriteCore/` | **audit-correctness** | `OutputValidator`, `EngineLimits`, and `PromptBuilder` — `audit-security` stood down and EVE-012 turned out to span both. |
| `EverestKit/Sources/Overlay/` + tests | *unowned* | `fix-keys` finished. `PanelKeyWindowTests` is `fix-keys`', confirmed. |
| `EverestKit/Sources/AppCore/` + tests | **fix-settings** | `EngineFactory.swift` was carved out to `fix-model`, now finished and returned. |
| `Everest/App/`, `Everest/Settings/` | **fix-settings** | Except `HotkeyManager.swift`, which is the lead's — the *bindings* were, never the rendering. |
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

- **Never write a commit hash you have not just read.** The lead put two
  invented hashes into a doc and a handover message within an hour — they look
  exactly like real ones, and the only way to find out is to go looking for a
  commit that does not exist. Read it from `git log` in the same command that
  uses it, or substitute it with `$(git log --format=%h -1 --grep=…)`.
- **Write the message from `git diff --cached`, not from the agent's report.**
  Explicit pathspecs are not enough. An agent lands more work in the same
  files between your `git status` and your `git add`, so the staged diff is a
  superset of what the report described — and a message written from the
  report then omits it. That is how `89824bc` came to carry the EVE-010
  key-status regression fix under a title naming only F3 and F5. Read what is
  actually staged before writing a word about it.
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
- **The errors cluster around paraphrase, not around reading.** Near enough
  every wrong claim made on this project — the lead's two already-fixed bug
  reports, two invented commit hashes, an agent's wrong assertion about
  `StubKeyMonitor`, another generalising the lead's test-gating from one
  sentence — came from restating something rather than opening it. Nobody was
  careless; they were accurate about a description of the thing. So:
  **an assertion about the tree carries a `file:line`, or it is marked as
  recalled.** Not "notice whether you read it" — there is no artefact proving
  you noticed, and §8 has already shown what happens to a rule you comply with
  by feeling careful. A citation is something you either typed or did not, and
  every claim that survived scrutiny tonight had one.
  **And a paraphrase of a signature is never the tiebreaker.** When a summary
  and the code disagree, the code wins without discussion — the signature is
  two lines away and free to read. The lead described a parameter as
  `recordInHistory`; it is `keepOutOfHistory`. Wiring to the summary would
  have inverted a privacy setting for exactly the users who asked for it,
  with both sides internally consistent and no test able to notice.
  **Its boundary:** it catches wrong claims *about the tree*, which is where
  all five landed. It does not catch correct readings followed by wrong
  reasoning — the two regressions introduced here were both of that kind, and
  a citation habit would have caught neither. Only a second pair of eyes on
  the same code did. That is what round 2 was for, and why one exists.
- **A test count is a required field in a report, not a habit.** The check
  below is mechanical for the reader and depends entirely on the writer, and
  its failure is silent — a report without a count reads completely normal.
- **Put a test count in every report, and check it before replying.** If the
  count in your tree does not match the count in their last message, you are
  reading something older than their work — cheaper than a diff, and it is one
  comparison rather than a judgement. Three stale reads between the lead and
  one agent tonight would each have been caught by it. **It cannot see a
  change that does not move the number** — folding an assertion into an
  existing test leaves the count agreeing while the trees differ, which is the
  very case it exists for. When the count matches and something still seems
  off, the tiebreak is the report filename or a specific line.
- **Claim new files in your report.** Three untracked files appeared —
  `LoadOnce.swift`, `PanelKeyWindowTests.swift`, `ShortcutCopy.swift` — that no
  report mentioned, so they sat uncommitted while the lead asked around. A file
  nobody claims cannot be committed, because its message would be a guess.
- **Ask the lead for an app build before believing app-target code.** Nothing
  under `Everest/` is in the SwiftPM graph, so `swift test` never compiles it
  and `swiftc -parse` does not check argument order. Two agents have now had
  app-target code sit broken in the tree without knowing.
