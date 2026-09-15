# Overlay round 2 — unpinned resets in `show()`

**Status: both closed. Overlay 71 → 73, one production line deleted.** `AppCoreTests` 63 green. No git command run.

Your last message said Overlay 71 and total 259; my tree agreed before I started, so we were reading the same thing.

---

## Commit grouping

| # | Item | Where |
|---|---|---|
| 1 | Held snapshot can outlive its transaction; two resets mutually redundant | `FloatingPanelController.swift`: **`clock.cancel()` deleted from `show()`** · test `showDropsTheHeldSnapshot` |
| 2 | `announcedKind` reset unpinned | test `showResetsTheAnnouncedKind` only — no production change |

`Sources/Overlay/AGENTS.md` carries a hunk for item 1. **59 lines**, with the spare line still spare.

No new files. Nothing untracked from me this round.

---

## Item 1 — and the redundant one is not the one I expected

Verified the mechanism rather than the summary. `flush()` (`StreamCoalescer.swift:45-48`) is the **only** reader of `held`, and it is only called from the timer closure. So:

- cancel kept, reset deleted → the timer never fires, `held` is unreachable, and the next `update` overwrites it anyway. No stale render.
- reset kept, cancel deleted → the timer fires against a fresh coalescer, `flush()` returns nil, nothing renders. No stale render.
- **both deleted** → A's timer flushes A's snapshot over B's panel. That is the visible consequence, and it needs both gone.

So "mutually redundant" is exactly right. But they are not equally redundant, and §1 says pick:

**The coalescer reset has a second, independent reason.** The held value is a `generating(text:)` — the user's rewrite. Keeping it after the transaction is superseded is precisely root §6's *"Only the current transaction's original in memory — more is an undeclared history of private selections."* That reason survives even if the stale render is impossible.

**`clock.cancel()` in `show()` has no reason of its own.** With a fresh coalescer, a surviving timer either finds nothing or releases *this* presentation's snapshot a few milliseconds early. Both harmless. And `PanelClock.schedule` replaces anything previously scheduled, so it does not accumulate.

So the cancel went. `dismiss()` keeps its cancel — nothing resets the coalescer there, and a timer firing after dismiss would render the panel back onto the screen.

**The redundant line was also hiding the test.** With `show()` cancelling, firing the clock afterwards proves nothing, because there is no timer to fire. That is why this reset could sit unpinned: any test you wrote for it passed vacuously. Deleting the cancel is what made an honest RED available:

```
✘ Test "a new presentation drops the snapshot the last one was holding"
  FloatingPanelControllerTests.swift:851: Expectation failed: clock.hasPending
✘ Test run with 72 tests in 11 suites failed after 0.138 seconds with 1 issue.
```

That failure is the **positive control** failing — the timer was gone, so the real assertion could not have meant anything. GREEN after deleting `clock.cancel()` from `show()`:

```
✔ Test run with 72 tests in 11 suites passed after 0.121 seconds.
```

**Mutation on a copy, to show the test pins the surviving reset** rather than merely the cancel's removal. Copy at `/tmp/emut2`, coalescer reset deleted there:

```
✘ Test "a new presentation drops the snapshot the last one was holding"
  FloatingPanelControllerTests.swift:853: Expectation failed: surface.presented.count == rendersAfterShow
✘ Test run with 72 tests in 11 suites failed after 0.143 seconds with 1 issue.
```

That is the stale rewrite rendering over the new panel, measured.

## Item 2 — `announcedKind`

Unpinned, but **not** redundant with anything, so this is a test with no production change.

No honest failing ordering was available — the reset is correct today — so it was proved by mutation on the same copy:

```
✘ Test "a new presentation announces itself even when it opens on the last one's state"
  FloatingPanelControllerTests.swift:834: Expectation failed:
  surface.announced == ["Reading selection", "Reading selection"]
✘ Test run with 73 tests in 11 suites failed after 0.135 seconds with 1 issue.
```

Disclosed per §0: mutation recovers the evidence, not the design benefit.

**Why it needed its own test rather than an assertion appended to the existing one.** `statesAreAnnouncedOncePerKind` ends on `.error`. A stale `announcedKind` of `.error` still differs from `.capturing`, so a following `show(.capturing)` announces anyway and the mutation survives. The new test opens two presentations on the *same* kind, which is the only shape that can fail. Folding it in would have produced a test that looked like it covered this and did not — the same defect as the vacuous one, so it was worth the extra test rather than the extra assertion.

**I left `announcedKind = nil` in `dismiss()` alone.** It looks unobservable — nothing renders between `dismiss()` and the next `show()`, which resets it again. But `update()` after `dismiss()` is reachable in principle and would render, so I cannot prove it dead, and deleting a line on "I could not find a path" is weaker than the §1 case I made for the cancel, where the redundancy is provable from `flush()` being the only reader. Flagging it rather than acting.

---

## Verification

Exit-status gated throughout, `rc=$?` not grep:

```
Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0
OverlayTests   ✔ 73
AppCoreTests   ✔ 63
```

One snag worth recording for whoever next runs a mutation copy: **a lean source-only copy no longer builds** — resolution tries to update `mlx-swift`'s submodules and the network failed (`curl 56 Recv failure`). Copying `.build/checkouts` and `.build/repositories` was not enough; it needed `.build/workspace-state.json` as well, after which it built offline in seconds. Worth knowing before concluding the tree is broken.

## Manual list

Unchanged: EVE-010 end-to-end through Everest itself, and the signed binary creating the tap — your checks 11 and 13. Nothing this round touches either.

## One stale line, not mine to edit

`docs/OWNERSHIP.md:13` still reads *"EVE-010's `PanelKeyWindowTests` landed from an unconfirmed author"*. I confirmed authorship two rounds ago and you committed it under my name; the row is just behind.
