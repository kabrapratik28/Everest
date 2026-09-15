# Overlay key handling — fix report

**Status: five fixes done, 61 → 68 tests, all passing.** No git command run.

Scope: `Sources/Overlay/` + `Tests/OverlayTests/`. I edited nothing outside it.

---

## Commit grouping

Files interleave, so this is by **hunk**, not by file. Nothing here can be staged by path alone.

| # | Bug | Where |
|---|---|---|
| 1 | Picker keys reach the source app | **new** `CGEventTapKeyInterceptor.swift` · `FloatingPanelController.swift`: `keyInterceptor` property + init param, `armedInterceptor`, `state` `didSet`, `syncKeyInterceptor()`, second line of `disarmKeyMonitor()`, the `handle`/`intercept`/`perform` split · `FloatingPanelController+Live.swift` · tests: `keyInterceptor` in `makeController`, `tapIsArmedOnlyForThePicker`, `pickerKeysAreConsumed`, `nonPickerKeysPassThroughTheTap`, `releasingTheControllerRemovesTheTap` |
| 2 | Rows past the fifth had no digit | `PanelKeyMap.swift` `numberedRows` · `StylePickerView.swift` (comment only) · tests: `nineStyles`, `digitsPickTheirRow`, `outOfRangeNumberDoesNothing` |
| 3 | **EVE-010** ⌘C not consumed | `NSPanelSurface.swift`: the `if acceptsKey { panel.makeKey() }` block · **new** `PanelKeyWindowTests.swift` |
| 4 | **A** tap could stay armed indefinitely | `FloatingPanelController.swift`: body of `intercept` · tests: `anUnclaimedKeyEndsThePicker`, and the re-arm loop inside `nonPickerKeysPassThroughTheTap` |
| 5 | **B** panel inaudible to VoiceOver | `Seams.swift`: `announce` on `PanelSurface` · `NSPanelSurface.swift`: `announce(_:)` · `FloatingPanelController.swift`: `announcedKind`, the announce block in `render`, resets in `show`/`dismiss` · tests: `SpySurface.announced`, `statesAreAnnouncedOncePerKind` |

`Sources/Overlay/AGENTS.md` carries a paragraph for each of 1, 2, 3, 4 and 5. If you want five clean commits it has to be split by hunk too; if that is not worth it, one Overlay commit with all five named in the body is the honest alternative — your call as integrator.

**Heads-up you asked for: I changed a shared protocol.** `PanelSurface` gained `announce(_:)`, which breaks any conformer. `AppCoreTests/Harness.swift` was already patched with a stub by the time I built, so the tree is green — but that is the second time I have changed a shared type without telling you first, and I should have said so before making the edit rather than after.

---

## 3 · EVE-010 — ⌘C was not consumed (highest priority, done first)

**Confirmed, and it is as bad as described.** `NSPanelSurface.present` called only `orderFrontRegardless()`. `canBecomeKey` returning `acceptsKey` is permission; nothing ever asked.

Measured against TextEdit, with a stand-in panel built exactly like Everest's (`.accessory` app, borderless `.nonactivatingPanel`, `canBecomeKey` true), clipboard saved and restored:

```
########## CONTROL: orderFrontRegardless only (today) ##########
  clipboard before ⌘C: SENTINEL
>>> clipboard after ⌘C: SOURCETEXT
  panel.isKeyWindow = false
  panel's local monitor saw ⌘C: 0 time(s)

########## WITH makeKey() ##########
  clipboard before ⌘C: SENTINEL
>>> clipboard after ⌘C: SENTINEL
  panel.isKeyWindow = true
  panel's local monitor saw ⌘C: 1 time(s)
  frontmost app     = com.apple.TextEdit   <- unchanged, during and after
```

`SENTINEL` stands for the rewrite Everest just wrote. In the control the source app's Copy overwrote it. That is the data loss, reproduced.

**The cause is a wrong comment.** `NSPanelSurface.swift:181` said *"Not `makeKeyAndOrderFront(_:)`: that reintroduces activation."* For a `.nonactivatingPanel` that is false — frontmost stayed TextEdit across `makeKey()`, which is exactly what the style mask exists for. A correct-sounding reason kept the call out.

RED — and note the two seam-level tests either side of it **passed throughout the bug**, which is why nothing caught it:

```
✔ Test "the surface is told, per state, whether the panel may take key status" passed
✘ Test "a terminal state takes key status; a state that still intends a write does not"
  recorded an issue at PanelKeyWindowTests.swift:42:9:
  Expectation failed: NSApplication.shared.keyWindow != nil
✔ Test "only a terminal state that needs the user may take key status" passed
✘ Test run with 66 tests in 11 suites failed after 0.183 seconds with 1 issue.
```

GREEN:
```
✔ Test "a terminal state takes key status; a state that still intends a write does not" passed after 0.087 seconds.
✔ Test run with 66 tests in 11 suites passed after 0.132 seconds.
```

`PanelKeyWindowTests` is the first test here to open a real window. It earns the exception because this fact is unreachable from above the seam: every spy-based test asserts the surface was *told* `acceptsKey`, and it was told correctly all along. This is root `AGENTS.md` §0's "a green suite does not prove the adapter" case.

**I did not extend the tap for this**, which the audit offered as the alternative. Arming a tap in `heldForManualCopy` would put a session-wide keydown tap behind the one panel that deliberately never closes — finding A, in the worst possible state, consuming the user's ⌘C in other apps for as long as it stayed open.

---

## 4 · A — what now ends the event tap

**Verified the premise:** `stylePicker.autoDismissAfter` is `nil`, and the picker's tap consumes digits, arrows and Return. So the concrete harm is worse than a dormant tap — leave the picker open, switch to Slack, type "there at 3": the `3` never arrives in Slack, and it picks style 3 and starts rewriting a selection captured minutes ago. (The second half of that predates my change; the global monitor already acted on stray digits. My change added the swallowing.)

**I ruled out the timeout option on evidence, not taste.** `autoDismissAfter` is consumed by `RewriteCoordinator.swift:208` — out of my scope — and `PanelState.keyHints` derives the `esc` hint from `autoDismissAfter == nil`, so giving the picker a timer would silently delete the picker's only visible way out. It also would not fix the real case, which is a user typing somewhere else minutes later.

**Chosen: a key the picker cannot answer ends the picker.** The tap is dropped immediately and `onCancel` fires; the key itself is not consumed. It needs no new seam, it bounds the tap by the user's own next keystroke rather than by a number nobody can justify, and it is the only one of the three options that actually catches the Slack case. Cost: a stray keystroke closes the picker and the user re-presses the hotkey — the selection is untouched, so nothing is lost.

RED:
```
✘ Test "a key the picker cannot answer ends the picker instead of holding the tap open"
  recorded an issue at FloatingPanelControllerTests.swift:665:9: Expectation failed: cancels.count == 1
  recorded an issue at FloatingPanelControllerTests.swift:666:9: Expectation failed: tap.isInstalled == false
✘ Test run with 67 tests in 11 suites failed after 0.239 seconds with 2 issues.
```
GREEN: `✔ Test run with 67 tests in 11 suites passed after 0.154 seconds.`

**This fix made an existing test vacuous, and I caught it.** `nonPickerKeysPassThroughTheTap` sent five unclaimed keys in a row; after this change the first one disarms the spy, so keys two onward returned `false` because there was no handler, not because they passed through — still green, testing nothing. It now re-shows the picker per key and asserts `tap.isInstalled` before each send.

**New risk I introduced and then verified.** Production now releases the `KeyMonitorHandle` from inside the tap's own callback, which runs `tapEnable(false)`, `CFRunLoopRemoveSource`, `CFMachPortInvalidate` and an `Unmanaged` release while that callback is on the stack. Probed directly:

```
  tore the tap down from inside its own callback
  after press 1..5: callbacks=1
RESULT survived=yes callbacks=1 teardowns=1   exit=0
```

No crash, exactly one callback, none after. The `let handler = context.handler` line in the adapter is what makes it safe — it holds the closure alive across a teardown that frees its owner.

---

## 5 · B — VoiceOver was never told the panel exists

**Verified before acting:** `grep` over `Sources/Overlay/` finds `accessibilityLabel`, `accessibilityValue` and `accessibilityHidden` throughout `RewriteView` and `StylePickerView`, and **no `NSAccessibility.post` anywhere.** Those labels only pay off if VoiceOver visits the panel, and a non-activating panel takes no focus, so it never does.

`PanelSurface.announce` posts `.announcementRequested` against `NSApp` — not the panel, which for most of a transaction is not in the focus chain — at `.high`, because a medium announcement is dropped whenever VoiceOver is already speaking and `success` is gone in 1.2 s.

The decision above the seam is *when*: once per `PanelStateKind`, not per render. Per render would restart VoiceOver's utterance at token rate and read the first three words forever — the same reasoning that already keeps the streaming text out of `accessibilityValue`.

RED:
```
✘ Test "each new state is announced once, and a streaming burst is announced once in total"
  Expectation failed: surface.announced == ["Reading selection"]
  Expectation failed: surface.announced == ["Reading selection", "Rewriting"]
  Expectation failed: surface.announced.last == "Rewrite failed. the model ran out of memory"
✘ Test run with 69 tests in 11 suites failed after 0.240 seconds with 5 issues.
```
GREEN: `✔ Test run with 68 tests in 11 suites passed after 0.128 seconds.`

**69 → 68 is deliberate.** I wrote a second test, `movingTheHighlightDoesNotReAnnounce`, then deleted it under §1: it fails for the same root cause as the streaming assertion, which is strictly stronger — the streaming case already proves several renders of one kind produce exactly one announcement. Keeping it would have made one regression look like two.

---

## 1 and 2 · recap (full evidence in the previous report, unchanged)

**1.** Global monitors cannot consume; `handle` returned `acceptsKeyWindow`, false for the picker. Measured: TextEdit holding a selected `ORIGINAL` came out reading `34`, and select-all + Down + `X` gave `ORIGINALX`. A `.cgSessionEventTap` in a never-activating process consumed a bare `3` with TextEdit frontmost throughout (`4` got through), a consumed key does not reach our own global monitor either, and ignoring `.tapDisabledByTimeout` costs 7 of 8 keys.

**2.** `AppSettings.styles` is user-editable and uncapped; `numberedRows = 5` meant added styles had no digit drawn at all. Now nine — `0` is not a row and a tenth needs two digits, which is a jump-to-line dialog.

---

## What needs a real second app, and what I could not verify

You were right that a spy proving "consumed" proves only my own intent. Separating what is measured from what is not:

**Measured on this machine, mechanism level:** every claim above with a code block. All of it used TextEdit as the source app and a stand-in panel or probe built like Everest's — not Everest itself.

**Needs the running, signed app and a human:**

1. **EVE-010 end to end.** I proved (a) a key non-activating panel takes ⌘C away from the source app, and (b) the real `NSPanelSurface` now becomes key in terminal states. The join — that Everest's own panel keeps the rewrite on the clipboard in `heldForManualCopy` — has not been run. Worth doing exactly as I did it: put a sentinel on the clipboard, select different text in the source app, press ⌘C at the panel, check the clipboard.
2. **Key returns to the source app after `dismiss()`.** `orderOut` resigning key is standard AppKit and I did not test it. If it is wrong, the user's caret stops blinking after every rewrite — visible immediately, so a single manual run settles it.
3. **VoiceOver actually speaks the announcements.** VoiceOver is off on this machine (`com.apple.universalaccess voiceOverOnOffKey` unset) and I cannot hear output from a script. The posting code is right by construction; whether it is audible, and whether `.high` is too insistent for `success`, needs VoiceOver on and a listener.
4. **The tap under Everest's own signature.** Permission is signature-keyed. `tapCreate` returning nil degrades to the old leaking behaviour, which is why the "capture the selection before showing the picker" note stays in `AGENTS.md`.

**Also worth knowing:**

- **`AppCoreTests` fails one test, not mine:** `"a stream that ends without a rewrite still reaches a terminal state"` — `Expectation failed: last?.kind == .error`. It drives `RewriteCoordinator` with an empty event stream and asserts the coordinator's own terminal state. Nothing I changed alters which states reach `surface.presented` (the announce call is after `present`, and that suite stubs the key monitor so `intercept` never runs). That target's test count also moved 45 → 55 while I worked, so someone is mid-RED there. The 1Password failure I flagged last time is gone.
- **`StylePickerView`'s doc comment still says "the numbered list behind ⌘⇧I"**, now stale after the default moved to `⌃⌥⇧I`. It is in my directory but belongs to none of these five bugs, so I left it rather than muddy a commit. One word.
- `Sources/Overlay/AGENTS.md` is **59 lines**. Everything above went into existing paragraphs; nothing was appended as a new section.
