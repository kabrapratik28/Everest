# EVE-024 — copy dismissed on the attempt

**Status: Overlay half done. Overlay 76 → 77.** `AppCoreTests` 76 green, doc at 59 lines. No git command run.

**One shell change is needed and is not mine to make** — `AppDelegate.swift:119` and `copyToPasteboard`. The exact diff is at the end; until it lands the app target will not compile, and `swift test` will not tell you that.

---

## The seam, which is what you asked for

**`onCopy` reports whether the rewrite is verifiably on the clipboard, and Overlay owns the dismissal.**

```swift
public var onCopy: (@MainActor (String) -> Bool)?

public func copy() {
    guard let text = state?.copyableText else { return }
    guard onCopy?(text) == true else { return }
    dismiss()
}
```

**Why not entirely on my side.** A read-back in Overlay needs `NSPasteboard`, which means a new seam, a production adapter and a spy, duplicating pasteboard knowledge that already lives in the shell — and it would split write-here from verify-there, which is how the two drift. The shell already owns the write; letting it own the evidence too is one boundary rather than two.

**Why not leave the dismissal in the shell.** A guard in `AppDelegate` is the one place `swift test` never compiles (root §4), so it would be the least verifiable spot in the app for the thing standing between the user and losing their rewrite. Overlay owning the dismissal makes it structural and testable.

**Blast radius, checked rather than assumed.** `FloatingPanelController.onCopy` has exactly one production setter — `AppDelegate.swift:119` — and six test sites, all in `OverlayTests`. `AppCoreTests` never sets it; `TextBridgeTests`' `onCopy` is an unrelated type on their keystroke double. `NSPanelSurface.onCopy` is a different property and is untouched.

## RED and GREEN

Seam absent:
```
FloatingPanelControllerTests.swift:936:41: error: cannot convert value of type 'Bool' to closure result type 'Void'
```

Seam present, decision absent:
```
✘ Test "copy does not take the panel away until the clipboard is verified"
  FloatingPanelControllerTests.swift:950: Expectation failed: surface.hides == 1
✘ Test run with 77 tests in 11 suites failed after 0.181 seconds with 1 issue.
```

GREEN: `✔ Test run with 77 tests in 11 suites passed after 0.079 seconds.`

**Mutation on a copy** for the other half, which had no honest ordering — before the change `copy()` never dismissed at all, so "stays up on a failed write" passed trivially. One mutation, per the new §0 rule: `copy()` restored to dismissing on the attempt.

```
✘ Test "copy does not take the panel away until the clipboard is verified"
  FloatingPanelControllerTests.swift:946: Expectation failed: surface.hides == 0
✘ Test run with 77 tests in 11 suites failed after 0.137 seconds with 1 issue.
```

## The trap this change walked into, which I want on the record

You named the shape last round — *a mechanism moved to a new context brings its whole contract*. It applied immediately, to me, in this change.

`intercept`'s second guard calls `endPicker()` when `run(action)` returns false. I had justified that as picker-only **by construction**: `run` only failed for `pickStyle` and `moveHighlight`, which `PanelKeyMap` only produces in the picker. Making `.copy` able to fail would have broken that argument silently — `run(.copy)` false → `endPicker()` → `cancel()` → **`heldForManualCopy` dismissed and the rewrite gone.** The exact bug I was fixing, through a different door.

I kept `run(.copy)` returning true — a failed clipboard write still *acted*, and consumption must not depend on the write succeeding — so the trap never fired. But "safe by construction" was one keystroke from being false, so `endPicker` now checks the state itself rather than trusting its callers, and the redundant check at the first call site is gone. Refactor, tests green throughout; no behaviour change, one latent trap removed.

## What I did not do

**No "couldn't copy" message.** A failed copy leaves the panel up and silent. Better than dismissing, worse than saying so — but a new state or a mutable detail line is a larger change than the bug warrants, and the panel still visibly holds the rewrite. Flagging rather than doing.

**The ⌘C hint still renders when the tap is dead**, from last round. Unchanged and still flagged.

## The shell half — for `fix-settings`

`Everest/App/AppDelegate.swift`. Two edits, and **`panel.dismiss()` must go** — Overlay does it now, and leaving both would dismiss on the attempt again:

```swift
// line 119
panel.onCopy = { [weak self] text in self?.copyToPasteboard(text) ?? false }

/// Returns whether the rewrite is verifiably on the clipboard.
///
/// The panel is the user's only copy until this says otherwise, so it reports
/// a read-back and not an attempt — and it must not dismiss the panel, which
/// `FloatingPanelController.copy()` now does on the strength of this answer.
private func copyToPasteboard(_ text: String) -> Bool {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return pasteboard.string(forType: .string) == text
}
```

Two notes for whoever takes it. The read-back narrows the overwrite window but does not close it — something can still clobber the clipboard after the read; gating on `changeCount` as well would tighten it, and `TextBridge` already has that pattern if it is judged worth the coupling. And `setString` is the throwing-free path, so the `writeObjects` throw `fix-docs` found does not arise here.

## Verification

```
Overlay rc=0 · OverlayTests rc=0 · AppCoreTests rc=0
OverlayTests   ✔ 77
AppCoreTests   ✔ 76
```

Built and run as one exit-status-gated command, `OverlayTests` alone, since the full suite is mid-RED on `isPreparing`.

**What this does not verify: the app target.** Nothing under `Everest/` is in the SwiftPM graph, so my suite is green with the shell uncompilable right now. That is `OWNERSHIP.md`'s "ask the lead for an app build" case, and this change is squarely in it.

## Manual list

Check 11 gains a second half worth doing in the same run: after the ⌘C at the panel confirms the rewrite is on the clipboard, note that **the panel closing is now itself the signal that the write was verified**. If it stays up, the copy did not stick — which is the new observable and is the point of the fix.
