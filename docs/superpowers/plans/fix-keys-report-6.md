# ⌘V regression, and the copy-only wording

**Status: both fixed. Overlay 73 → 75.** `AppCoreTests` 66 green, doc at 59 lines. No git command run.

Your last message said Overlay 73 / total 261; my tree agreed before I started.

---

## Commit grouping

| # | Item | Where |
|---|---|---|
| 1 | Panel eats ⌘V | `PanelState.swift`: `acceptsKeyWindow` false in every case, **new** `needsKeyInterception` · `NSPanelSurface.swift`: `makeKey()` removed · `FloatingPanelController.swift`: `syncKeyInterceptor` arms on `needsKeyInterception`, `intercept`'s stand-down scoped to the picker · tests: `statesHoldingARewriteConsumeOnlyCommandC`, `anUnclaimedKeyDoesNotEndATerminalPanel`, `PanelKeyWindowTests` inverted, `onlyPickerAndRewriteStatesInterceptKeys` replacing the key-status test, `commandCCopiesWithoutTheMonitorsClaimingIt` retitled, `commandCIsConsumedWhenTheHandlerDismisses` retargeted at the tap, `keyStatusFollowsTheState` deleted |
| 2 | Copy-only wording | `PanelState.swift`: `title` and `detail` for `.readOnly` and `.targetChanged` · test `copyOnlyOutcomesLeadWithTheAction` |

`Sources/Overlay/AGENTS.md` carries hunks for both. No new files.

---

## 1 — reproduced, and it is my EVE-010 fix

Measured rather than derived, against TextEdit, with a stand-in panel built like Everest's and the clipboard saved and restored:

```
###### CONTROL: no makeKey ######
>>> TextEdit document after ⌘V: PASTEME
mode: no makeKey  isKeyWindow=false

###### WITH makeKey() — today's code ######
>>> TextEdit document after ⌘V:
mode: makeKey() — today  isKeyWindow=true
```

Pratik's report exactly. A key window receives every keystroke; this panel answers none, so ⌘V died in an empty responder chain. Your trace was right in every part.

**And the fix verified in the shape production now has** — panel never key, tap armed and consuming ⌘C:

```
>>> TextEdit after ⌘V: YOUR REWRITE
panel up, isKeyWindow=false, tap armed
tap consumed: []
```

### You were right to overrule me, and for a reason I had not weighed

In round 1 I declined the tap for terminal states because `heldForManualCopy` never closes. That is still true and the tap does sit there until the panel goes. What I had not weighed is the comparison you made: the key window steals **every** key for the same duration, where the tap steals one. My objection applied more strongly to the option I chose.

**I could not keep the tap out of `heldForManualCopy`**, and I do not think it can be done: that is the state where ⌘C matters most, because the panel holds the user's only copy. Excluding it reinstates EVE-010 in precisely the worst place. What I could narrow is the other end — `refused` and `error` hold no rewrite, so `PanelKeyMap` never resolves `.copy` there and no tap is armed. Interception is now `stylePicker` plus the three states with `copyableText`, not all five terminal states.

### The dangerous part of widening the tap, which the brief did not mention

Arming the tap outside the picker made `intercept`'s stand-down rule apply to terminal panels — **any stray keystroke would have cancelled `heldForManualCopy` and thrown the rewrite away.** That is worse than the bug being fixed. It had its own RED:

```
✘ Test "a key it cannot answer does not close a panel holding the only copy"
  FloatingPanelControllerTests.swift:863: Expectation failed: cancels.count == 0
✘ Test run with 75 tests in 11 suites failed after 0.160 seconds with 1 issue.
```

Standing down is now the picker's alone: the picker is a question, a panel holding a rewrite is not.

### REDs and GREENs, in order

**Tap armed for rewrite-holding states:**
```
✘ Test "a state holding a rewrite takes ⌘C through the tap and leaves ⌘V alone"
  FloatingPanelControllerTests.swift:837: Expectation failed: tap.isInstalled
  FloatingPanelControllerTests.swift:840: Expectation failed: tap.send(PanelKeyMapTests.commandC) == true
  FloatingPanelControllerTests.swift:841: Expectation failed: copied.value == "the whole rewrite"
✘ Test run with 74 tests in 11 suites failed after 0.096 seconds with 3 issues.
```
→ `✔ Test run with 74 tests in 11 suites passed after 0.087 seconds.`

**Stand-down scoped to the picker:** RED above → `✔ Test run with 75 tests ... passed after 0.111 seconds.`

**Never key:**
```
✘ Test "no state takes key status, so the app underneath keeps its own keystrokes"
  PanelKeyWindowTests.swift:51: Expectation failed: NSApplication.shared.keyWindow == nil   [×3]
✘ Test run with 75 tests in 11 suites failed after 0.090 seconds with 3 issues.
```
Three of four sampled states; `generating` was already correct. → `✔ 74 tests passed` after the fix and the four consequent test changes.

### Four tests changed, all because their premise was the bug

Listing them because "I changed the test" should always draw a look:

- **`keyStatusFollowsTheState` — deleted.** It asserted the surface is told `acceptsKey` per state. Now a constant, and `PanelKeyWindowTests` checks the real window, which catches strictly more (including `makeKey()` being re-added without touching `PanelState`).
- **`onlyTerminalStatesAcceptKey` → `onlyPickerAndRewriteStatesInterceptKeys`.** Same shape, pointed at the decision that now exists: which states take a key from the app underneath. Still per-state and still fails on a twelfth state that gets it wrong.
- **`commandCCopiesAndIsConsumedOnlyInATerminalState` → `commandCCopiesWithoutTheMonitorsClaimingIt`.** The monitors act on ⌘C and no longer claim it; `copied.value` is the positive control.
- **`commandCIsConsumedWhenTheHandlerDismisses` — retargeted, not deleted.** Its mechanism (key-window consumption) is gone, but its *hazard* is not: `onCopy` still dismisses synchronously, and that now releases the tap **from inside its own callback**. Pointed at the tap, it guards a live path — the one the `let handler = context.handler` line in the adapter exists for.

### One thing I did not do, because of your protocol rule

`acceptsKeyWindow` is now a constant `false`, which makes it and `present`'s `acceptsKey` parameter and `NonActivatingPanel.acceptsKey` all deletable. **Deleting them changes `PanelSurface`**, so it comes to you first rather than as a surprise in a diff. Say the word and it is a ten-minute follow-up; I have left a line in `AGENTS.md` recording that it is pending rather than overlooked.

### One trade-off worth stating plainly

⌘C consumption now depends entirely on the tap, so if Accessibility is revoked `tapCreate` returns nil and EVE-010 comes back — where previously the key window would have covered it. The app cannot read a selection without Accessibility either, so this is a broken state already, but it is strictly worse than before on that one path.

## 2 — the wording

RED:
```
✘ Test "the copy-only outcomes lead with the keystroke and explain themselves differently"
  PanelStateTests.swift:112: Expectation failed: readOnly.title.contains("⌘V")
  PanelStateTests.swift:113: Expectation failed: moved.title.contains("⌘V")
  PanelStateTests.swift:116: Expectation failed: readOnly.detail != moved.detail
✘ Test run with 75 tests in 11 suites failed after 0.098 seconds with 3 issues.
```
GREEN: `✔ Test run with 75 tests in 11 suites passed after 0.137 seconds.`

| | Title | Detail |
|---|---|---|
| `.readOnly` | **Press ⌘V to paste your rewrite** | Everest can't type into this app, so your rewrite is on the clipboard. |
| `.targetChanged` | **Press ⌘V to paste your rewrite** | The text moved before Everest could replace it, so your rewrite is on the clipboard. |

Close to your sketch, with two departures:

**The titles are identical and the details are not.** The *action* is the same in both cases, so making the headlines differ would be difference for its own sake. What was indistinguishable was the reason, and that is now what differs.

**I did not say "paste it into this app".** For `.readOnly` that would sometimes be a lie: the state means the app cannot be typed into, and while a terminal accepts a paste, a PDF or ordinary web prose does not. "Press ⌘V to paste your rewrite" says what to press without promising where it will land, and the detail explains why not here. `.targetChanged` *is* an editable app, so pasting back works there — the two genuinely differ in what the user can do, not only in why.

I did not touch `heldForManualCopy`, which you did not ask about and which is a different situation: nothing has been copied yet, so "Copy this before closing" is still the right first sentence.

**One thing to check in the VoiceOver pass.** `accessibilityValue` is `"\(title). \(detail)"`, so the glyph `⌘V` is now in spoken text. Elsewhere this directory deliberately keeps glyphs out of the a11y layer — keycap badges are `.accessibilityHidden(true)` and hints speak through `accessibilityLabel(for:)`. macOS usually reads `⌘` as "command", but I could not verify it here and it belongs with the VoiceOver item already on your list.

## Verification

Exit-status gated throughout:

```
Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0
OverlayTests   ✔ 75
AppCoreTests   ✔ 66
```

No mutation needed this round: every new test had an honest RED.

## Manual list

**Check 12 is now stale.** "Key returns to the source app after dismiss" was about the panel taking key status, which no longer happens — nothing to return. It can be struck.

Checks 11 and 13 stand. **11 gets easier and more important**: ⌘C consumption is now the tap's alone, so that check exercises the whole mechanism rather than half of it. Add to it, if you like: press ⌘V at the panel and confirm it reaches the app underneath — that is the regression Pratik found, and it is one keystroke in the same run.
