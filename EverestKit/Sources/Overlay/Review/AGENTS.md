# Overlay/Review: the pane that waits for an answer

The review state: the rewrite shown before anything reaches the document, edited or read as tracked changes, answered with ↩ (replace) or esc (keep the original). Split out of `Overlay/` because that directory's doc was at its budget, and these decisions share nothing with streaming or the picker. `PanelState`, `PanelKeyMap` and the controller stay in `Overlay/`; what is special about review is written here.

## The one key state, and why it is safe here

A key window receives every keystroke. That is why no other state may be key (`Overlay/AGENTS.md`), and it is exactly what an editor needs: ⌘V, ⌘A, ⌘Z and the arrows belong to the editor while the pane is up.

It is safe only because nothing is read or written while the pane is key. Capture happened before the rewrite. On ↩ the surface orders the panel out before drawing `.applying`, the only way to resign key, and `ReplacementService` waits up to 500 ms for the target app to report a focused element again before its validator runs, unchanged and with the final word. The panel is non-activating, so the target app stays frontmost the whole time and `TargetValidator`'s frontmost check holds. If focus does not come back in time the validator refuses and the rewrite goes to the clipboard under "Press ⌘V to paste your rewrite": degraded, never lost. `PanelKeyWindowTests` is the one test that can see this: the real panel is key in review and not key once `.applying` is drawn. *Measured 2026-09-28, macOS 26.7: frontmost stayed the source app while the pane was key; ↩ to replaced text took 120 ms in TextEdit (Accessibility write) and 282 ms in a Chrome textarea (paste route); `docs/MANUAL-CHECKS.md` has the apps still to check.*

## ↩ and ⌘D go through the key monitor, and only with focus

Same path as every other key: monitor, `PanelKeyMap`, controller, so the mapping is tested. The local monitor sees them before the editor and swallows them, which is why ↩ never lands as a new line; ⇧↩ is left alone and does.

The global monitor also reports keys typed in other apps. A Return typed into Slack after the user clicked away must reach Slack and replace nothing, so review's keys act only while `surface.hasKeyFocus`. Nor while an input method is composing (`isComposingText`), where Return commits the composition. esc works from anywhere, as in every state: a leaked Escape is harmless.

⌘D (D for diff) switches views. It was ⇥ first, and a ⇥ keycap told nobody which key it was; a letter with ⌘ reads at a glance and never types into the editor, so Tab is ordinary typing again.

## One answer per review

`reviewIsSpent`: a second ↩ can arrive before the coordinator takes the panel down, and must not write twice. An emptied editor is not an answer, because replacing a selection with nothing deletes it. The coordinator parks the transaction in `pendingReview` and `supersede()` clears it (`AppCore/AGENTS.md`), so a ↩ from a panel that a new hotkey press replaced finds nothing to write.

## The changes view is a word diff, and it never re-spaces

`WordDiff` splits on words *with* their trailing whitespace and compares them without it, so a changed line break is not a changed word, and the kept and added runs join back into the rewrite byte for byte. Built on the stdlib's `difference(from:by:)`; no dependency. Removed runs come before added runs at each change, the order people read track changes in.

Struck through for removed, underlined for added, colour on top, so the marks survive a reader who cannot tell the red from the green. Read-only: ⌘D goes back to the editor with any edits intact. Typing in the changes view to switch automatically would mean mapping the diff's offsets back onto the text, and nobody has asked for it.

## The editor

`NSTextView`, not SwiftUI's `TextEditor`: only the AppKit view can say an input method is composing. `updateNSView` does nothing on purpose, because a redraw must never put the original text back over the user's edits; switching views builds a new editor with the edits carried across. `ImageRenderer` cannot draw it, so `ScreenshotGenerator` shoots only the changes view.

## Tests

`PanelStateTests` (review holds the rewrite, takes key, hints), `PanelKeyMapTests.reviewKeys`, `FloatingPanelControllerTests` (focus and composition gate with positive controls, one answer, empty text, ⌘D carrying edits, drops), `PanelKeyWindowTests` (the real window), `WordDiffTests`. Everything else here is hand-checked: `docs/MANUAL-CHECKS.md`.
