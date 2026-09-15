# `.success` dismisses immediately

**Status: done. Overlay 77, doc at 59 lines.** `AppCoreTests` 76 green. No git command run.

This is a one-line production change on top of report 8; the EVE-024 shell half is still outstanding and unchanged.

---

## Your question: `.zero` or skip the presentation

**`.zero`, and keep presenting it — and the reason is the one you were pointing at when you asked what it does to `announcedKind`.**

Skipping the presentation would remove the announcement, because `render` is what announces. `.success` is the **only confirmation a screen reader user gets on the replaced path**: a sighted user sees their document change, and a VoiceOver user does not. So the state whose entire job is confirmation would go silent for the people who need it most, in an app built on the Accessibility API.

That inverts the trade. The frame of flash costs a sighted user a few milliseconds of something harmless; skipping it costs a blind user the only signal that anything happened. `.zero` keeps both: the announcement fires, and the panel is gone by the next turn of the run loop.

It is also the smaller change and stays inside my module — `PanelOutcome.swift:20` is where `.success` is produced, so not presenting it would have been an AppCore change I would have had to hand to `fix-settings` anyway.

**On your "I would rather that fall out of the design than be special-cased":** it does, in the other direction. Nothing needed special-casing because the state is still presented and still dismissed through the ordinary `autoDismissAfter` path — `announcedKind`, the coalescer and the auto-dismiss path are all untouched.

## Only `.success`, and the test guards both directions

Your constraint was that `.readOnly`, `.targetChanged` and `.heldForManualCopy` keep their timings. The existing test only asserted *whether* each state dismisses, so it would have stayed green if someone zeroed `readOnly` too. It now asserts **`success` is zero and every other dismissing state is strictly greater than zero** — so the "only `.success`" part is pinned rather than trusted.

RED:
```
✘ Test "heldForManualCopy never auto-dismisses; success dismisses at once and nothing else does"
  PanelStateTests.swift:70: Expectation failed: delay == .zero
✘ Test run with 77 tests in 11 suites failed after 0.171 seconds with 1 issue.
```
GREEN: `✔ Test run with 77 tests in 11 suites passed after 0.114 seconds.`

Folded into the existing auto-dismiss test rather than added beside it: *which* states close themselves and *how fast* are two halves of one table, and a second test would have failed alongside the first on any change to it.

**`AppCoreTests` was already coupled correctly.** `RewriteCoordinatorTests.swift:188` asserts `sleeper.requested.first == PanelState.success.autoDismissAfter` — it reads the value rather than hardcoding 1200, so it followed the change without edits. 76 green.

## The auto-replace-off path is unchanged, and that falls out too

Your constraint was that with auto-replace off the panel must stay long enough to say the rewrite is on the clipboard. Nothing here touches it: that path ends in `.readOnly` or `.targetChanged`, both still 6 s, and the test now actively forbids either being zeroed. The immediate dismiss belongs to `.success`, which is only reached when the text was actually replaced — so it is already keyed to the replaced path rather than to the transaction finishing, exactly as you asked.

## The settings-composition test — I cannot pin it, please route it

Auto-replace on **plus** keep-out-of-history on, leaving the clipboard as the user left it. **Overlay never touches the clipboard** — I grepped `Sources/Overlay/` for `NSPasteboard` and the only hits are the word "pasteboard" in four doc comments. There is no seam here to assert against and no double I could write that would mean anything.

It needs to sit where both halves are visible — the transaction's clipboard borrow-and-restore and the replace path. That is `AppCore` plus `fix-docs`' work, so routing it is the right call rather than either side assuming the other has it. The specific thing worth asserting, in case it helps whoever takes it: after a rewrite with both settings on, `changeCount` and the clipboard contents should both be what they were before the hotkey — not merely "the rewrite is not on the clipboard", since restoring the wrong thing also satisfies that.

## Verification

```
Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0
OverlayTests   ✔ 77
AppCoreTests   ✔ 76
```

Exit-status gated, `OverlayTests` built and run as one command.

**Still not verified: the app target**, which the EVE-024 seam change leaves uncompilable until `fix-settings` takes the `AppDelegate` half from report 8. That is unchanged by this round and is the one thing blocking a build Pratik could test.

## Manual list

Nothing new. Worth folding into the existing smoke check 3 ("one rewrite in a native text field"): the panel should now be gone the instant the text changes, rather than sitting over it for a beat. That is Pratik's actual complaint and it is observable in the check he already runs.
