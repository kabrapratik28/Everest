# Working rules

Hard-won during a multi-agent build of this app. Every one exists because
something went wrong in a way that was invisible at the time, and every one
asks you to produce an artefact rather than to be careful — a rule you satisfy
by feeling principled catches nobody.

Read with root `AGENTS.md` §0 (the TDD Iron Law) and §8 (the five ways to get a
false green).

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
- **Check a report for pasted runner output before accepting it, and do it
  regardless of how well written it is.** The lead enforced §0's paste-the-RED
  rule on two agents and not on a third, because the third's reports were more
  pleasant to read — 722 lines, 29 sections, 2 lines of actual test output,
  accepted for hours. Persuasiveness is not evidence, and grading on prose
  selects against exactly the reports that most need checking. The artefact is
  countable: `grep -c '✘'`.
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
- **Report app-target files as "parses; not type-checked", never as clean.**
  `swiftc -parse` is syntax only — it cannot see an argument type, a closure
  result type, or memberwise-init order, which are three of the four
  app-target breaks this project has had. "All six app files parse" reads as
  "compile" and the phrasing was overclaiming even when the facts under it
  were right. "Ready for a build" means the package is green and the shell is
  syntactically valid; only the lead's build settles the rest.
- **Ask the lead for an app build before believing app-target code.** Nothing
  under `Everest/` is in the SwiftPM graph, so `swift test` never compiles it
  and `swiftc -parse` does not check argument order. Two agents have now had
  app-target code sit broken in the tree without knowing.
