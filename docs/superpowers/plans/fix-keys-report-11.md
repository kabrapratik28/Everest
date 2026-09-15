# Tick at 1 s, and the failure panel's words

**Status: both done. Overlay 77, doc at 59 lines.** No git command run. Ready to build.

---

## 1. `.success` at 1 second — and the reason is not what either of us thought

`PanelState.swift:172` is `.seconds(1)`.

**Your verification instruction was the right one to give, because the test *cannot* fail for this change and it would have been easy to let it look like it validated one.** It pins two relations — above zero, below every other dismissing state — and 1 s satisfies both, so it passed without ever being at risk. That is by design; the number is a taste call and pinning it would be a constant assertion.

So I proved the relations are enforced rather than claimed, by mutation on a copy (one mutation, per §0), setting `.success` to 7 s — past `readOnly`'s 6:

```
✘ Test "heldForManualCopy never auto-dismisses; success is visible but the briefest of those that do"
  PanelStateTests.swift:79: Expectation failed: delay > success
  PanelStateTests.swift:79: Expectation failed: delay > success
✘ Test run with 77 tests in 11 suites failed after 0.090 seconds with 2 issues.
```

Two failures, one each for `readOnly` and `targetChanged`. The lower relation already REDed last round at `.zero`. Both directions bite; neither is decorative.

### The look you asked for, and it found a third explanation

You offered two: 500 ms too brief, or `.success` never presented. It is a third, and it is measured.

`NSPanelSurface.present` resizes with `setFrame(_:display:animate:)`, and `animate` is `!reduceMotion`. **That call blocks.** I measured it on a panel collapsing from a streaming height to a one-line tick, which is exactly the `applying` → `success` transition:

```
AppKit's own answer, animationResizeTime(tick) = 292.5 ms
setFrame(animate: true) blocked for 293 ms
of a 500 ms tick that leaves 207 ms static (41%)
of a 1000 ms tick that leaves 707 ms static (71%)
```

So the tick was on screen for the full 500 ms, but for 293 of them the panel was **shrinking**. In the corner of the eye a shrinking panel reads as *going away*, not as *confirming* — which fits "I am not able to see green tick" better than either "too brief" or "never shown". Pratik was looking at his text, and the only thing moving in his periphery was the panel leaving.

1 s takes the still part from 207 ms to 707 ms: **3.4× the part that can register, not 2×.** So your fallback is better-founded than the reasoning either of us used to pick it.

**The cheaper lever, if this ever needs to come back down:** present `.success` without the animated resize. 500 ms fully static beats 1 s mostly moving. That is a behaviour change and needs its own test, so I have not done it — it is recorded in the code and in `AGENTS.md` as the next move rather than another duration guess.

On the main-thread question specifically: `apply` does run inside `await MainActor.run` (`RewriteCoordinator.swift:231`), so the paste does block the main actor — but `settle(.success)` happens strictly after it returns, and the panel's own throttle does not delay non-`generating` states. I found no mechanism by which the paste's blocking eats the tick. **The animation does, and that I could measure.**

## 2. The failure panel

`PanelState.swift:132` is now **"Press ⌘C, then paste your rewrite"**, over the `reason`.

Two of Pratik's three requirements were already met, which is worth him knowing:

- **Keep the panel open** — `autoDismissAfter` is `nil` and pinned by the auto-dismiss test.
- **Keep the rewrite visible in it** — `bodyText` returns the text and `bodyTextIsPerState` (`PanelStateTests.swift:104`) already pins which states show it.

So only the headline needed work, and the defect was the one he reported for the copy-only states: the action was in the small grey line while the headline read as a diagnosis.

**The invariant I pinned is sharper than "leads with the action".** The *choice* of glyph records where the rewrite actually is:

| State | Says | Because |
|---|---|---|
| `readOnly`, `targetChanged` | ⌘V | already on the clipboard; the move left is to paste |
| `heldForManualCopy` | ⌘C | copied nothing — the clipboard is the user's own and untouched |

Getting those backwards is exactly the "do not promise the clipboard holds it" failure you flagged, so the test now asserts each title contains its own glyph **and not the other one**. That is a real invariant rather than a string check: it fails if someone reaches for the familiar ⌘V wording in the state where it would be a lie.

RED:
```
✘ Test "the copy-only outcomes lead with the keystroke and explain themselves differently"
  PanelStateTests.swift:148: Expectation failed: held.title.contains("⌘C")
✘ Test run with 77 tests in 11 suites failed after 0.091 seconds with 1 issue.
```
GREEN: `✔ Test run with 77 tests in 11 suites passed after 0.085 seconds.`

Folded into the existing copy test rather than added beside it — all three are one behaviour, and a second test would have failed alongside the first on any change to the headlines.

Both steps are named because neither happens on its own: ⌘C puts it on the clipboard, and the paste is the user's. Nothing here closes on a timer, so there is no rush implied.

## Verification

```
Overlay rc=0 · OverlayTests rc=0
OverlayTests   ✔ 77
```

`PanelState.swift:172` = `.seconds(1)`, `PanelState.swift:132` = `"Press ⌘C, then paste your rewrite"`, both read back from the tree rather than from memory.

I did not run `AppCoreTests` this round — last round it failed to build on `TextBridge/SelectionCoordinator.swift:204` mid-`viaClipboard`, and `fix-docs` has landed since, so its state is theirs to report rather than mine to infer.

## Manual list

Smoke check 3 now has two observables rather than one: the tick should be visible for about a second after the text changes, and — if it still is not — the next lever is the animated resize, not another duration. Worth writing that into the check so whoever runs it knows what a failure would mean rather than just recording "still cannot see it".
