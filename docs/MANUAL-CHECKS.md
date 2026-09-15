# Manual checks — what no test on this machine can reach

Every item here was named by the agent that wrote the fix, as the part of its
own claim it could not verify. Collected in one place so the run is a checklist
rather than a reconstruction from six reports.

**Why these exist rather than being tests.** Root `AGENTS.md` §0: some things
cannot be unit-tested — Accessibility against a live app, a real multi-GB
download, Metal inference, whether a screen reader actually speaks. Test at the
nearest seam and say plainly what stays manual. This is the "say plainly" half.

Run after any rebuild that changes signing, and after the first build following
round 1.

## Smoke, in order — stop if one fails

1. **Accessibility survived the rebuild.** The point of the hardcoded
   certificate SHA-1 in `project.yml` is that the designated requirement does
   not change between builds. If Everest is missing from System Settings ▸
   Privacy ▸ Accessibility, or is listed but not working, the signing identity
   moved and every check below is invalid.
2. **Model still loads.** ~3.3 GB is already in
   `~/Library/Application Support/Everest/Models/`. First rewrite after launch
   should stream, not re-download.
3. **One rewrite in a native text field** (TextEdit). In-place replacement.

**Check the menu for the real binding before pressing anything.** On this Mac
the stored shortcut is `⌘U` / `⌘⇧U`, not the `⌃⌥I` default — `KeyboardShortcuts`
persists a binding once set, so changing the default in code never reaches an
install that already has one. The menu bar renders the live value now (EVE-007),
so read it there rather than assuming. Note `⌘U` is Underline, the same class of
collision the default was changed to escape, and `ShortcutNotice` only warns
about `⌘I`.

**Scripted keystrokes cannot test any of this.** Carbon global hotkeys
(`RegisterEventHotKey`, which is what `KeyboardShortcuts` wraps) do not reliably
fire for events synthesised by System Events, so an AppleScript harness measures
what the *target app* does with the chord and never reaches Everest. An hour was
lost to that; it produced one unreproducible scare and no information.

## First run on fresh defaults — the highest-value pass

Most of the Settings batch lands here and no test reaches it. **Needs a
throwaway defaults domain, not the real one**, or it destroys the working
install's settings:

```bash
defaults export com.kabrapratik.Everest /tmp/everest-backup.plist   # export, NOT read
defaults delete com.kabrapratik.Everest
# restore afterwards:
defaults import com.kabrapratik.Everest /tmp/everest-backup.plist
```

`export`/`import` are the pair. `defaults read` prints old-style text that
`import` cannot consume, so a backup taken with `read` looks fine and restores
nothing.

4. Guide appears at all — it is keyed to stored completion now, not to the TCC
   grant, so it must appear even though Accessibility is already granted.
5. The model step offers a **download** for the default engine, with its size,
   rather than a disabled row reading "In use". That was the first-run dead
   end: the default engine is the *absent* one on a new Mac.
6. The download either succeeds or says why. It used to fail silently through
   `try?`, leaving a vanished bar and an unchanged status.
7. Continue is gated on the engine actually being ready.
8. Done, then relaunch — the guide must not come back.
9. **Repeat, but close the guide midway.** It must resume at the same step, not
   restart and not be skipped forever.
10. The 17.2 GB model shows why it is unavailable if this Mac cannot hold it,
    rather than downloading and then swapping.

## Needs a second app

11. **EVE-010 end to end.** Put a sentinel string on the clipboard. Select
   *different* text in the source app, trigger a rewrite that lands in
   `heldForManualCopy`, press ⌘C at the panel, read the clipboard. Expect the
   rewrite. Before the fix this gave you the source app's own selection,
   because its Copy ran after ours. Both halves are proven separately; the join
   is not.
12. **Key returns to the source app after dismiss.** Caret keeps blinking in the
   source app once the panel goes. `orderOut` resigning key is standard AppKit
   and was not tested; if it is wrong this is visible immediately.
13. **The event tap under Everest's own signature.** Tap creation is
   signature-keyed. Open the style picker, press `3`, and confirm no `3`
   appears in the source app. If `tapCreate` returns nil the picker silently
   degrades to the old leaking behaviour — which is why "capture before showing
   the picker" stays in `Overlay/AGENTS.md`.
14. **Chord still held during clipboard fallback.** `onKeyDown` fires while the
   hotkey is physically down, and capture rung 9 posts a synthetic ⌘C. Confirm
   a clipboard-fallback target (a terminal, a PDF) still captures with the
   chord held. If not, `onKeyUp` is the fix.

## Google Docs — needs a real signed-in document

15. Select a paragraph, hotkey → `.copiedOnly`, not a refusal.
16. Then Gmail **in the same window, within ten minutes** → in place, not
   copy-only. This is the `StrategyCache` guard: one Docs capture must not make
   ordinary Chrome text take the clipboard path.
17. Doc with nothing selected → the `.nothingCaptured` sentence, which names
    Google Docs.
18. Copy a sentinel, rewrite in Docs, confirm the sentinel comes back.
19. **IME composition.** Docs' hidden input is empty at rest but holds text
    mid-composition, which makes it report a non-zero character count and can
    restore the old `.noSelection` refusal. Harmless — a refusal, never a wrong
    rewrite — but it reads as flakiness.
20. A deliberately slow or huge selection, against a real app rather than a
    fake, to exercise the late-copy path.
21. **Screenshot on the clipboard, then rewrite in Docs.** Must now name the
    *clipboard* as the obstacle and tell you to copy a word of text over it —
    not say Google Docs cannot be read. No test on this machine reaches the
    real pairing of a canvas editor and an oversize pasteboard.

## Joins round 2 traced but could not settle by reading

Handed over rather than dropped. Each has a mechanism traced and a conclusion
that needs the running app.

22. **Download and hotkey racing the same missing model — the one to do first.**
    `LoadOnce` single-flights the *load*; nothing single-flights the
    *download*. The bytes are safe — `swift-huggingface` guards each blob with
    an `flock(2)` lock and re-checks the cache inside it, which is what
    `.locks/` is for — but the second caller **blocks on that lock**, and if no
    progress fires before it is acquired the panel sits on
    `preparing(progress: nil)` for minutes. `RewriteCoordinator.prepare`'s
    generation check lives inside the `for await` body, so with nothing yielded
    the download is never cancelled. *Do:* delete the model, click Download,
    press the hotkey while it transfers, watch the panel and press Escape.
    The whole dependency trace is two line refs, so nobody need redo it: the
    `flock` re-check is `HubClient+Files.swift:520-537`, and the reason
    cancellation cannot reach it is `RewriteCoordinator.prepare:208-214`.
23. **Two transactions sharing one generation (F2).** Needs to know whether a
    Carbon hot-key `CFRunLoopSource` queued during the capture block is
    serviced before an already-enqueued main-actor job — unanswerable by
    reading. *Do:* log the generation at `begin()` and at `run:128`, then
    hammer the hotkey during a clipboard-path capture (terminal or Google Docs)
    and look for two `run`s reporting the same value.
24. **F3's window in wall-clock terms.** *Do:* picker up, press an unanswerable
    key immediately followed by a digit; see whether the digit lands in the
    document.
25. **A key the tap claimed never reaching our own monitor.** Measured by
    `fix-keys`, never independently confirmed, and the whole no-double-handling
    property rests on it.
26. **`NSPanelSurface.contentHeight` clamping the scroll origin.** *Do:* long
    streaming rewrite, scroll up mid-stream, see whether it snaps to the top on
    each frame.
27. **`LoadOnce` continuation ordering.** A caller joining `inFlight` may return
    before the first assigns `loaded`. Actor FIFO probably makes it safe; that
    is an assumption, not an established fact. Failure would be a spurious
    `modelNotLoaded` on a warm model.

## The two new settings — neither is verifiable here

28. **Does your clipboard manager actually honour `TransientType`?** The
    "keep rewrites out of clipboard history" setting rests entirely on third
    parties obeying a convention, and **nobody on this project has ever
    watched one obey it** — we assert in two comments that every mainstream
    manager does. Test against the manager you actually run, by name. If it
    ignores the marker the setting silently does nothing, and you believe your
    rewrites are out of history while they are in it. **A privacy toggle that
    lies is worse than no toggle**, so if yours ignores it, say so and the
    honest move is to name the limitation in the UI or drop the setting.
29. **Does auto-replace ever fire?** It only does anything where
    Accessibility reports a target non-editable *and* a paste nonetheless
    lands — a WebKit `contenteditable`, which is the case the `isEditable`
    comment was written about. The test proves the branch is taken; only a
    real editor proves those targets accept a paste at all. If they do not,
    you get the same copy-only as before **plus a ~450 ms wait**, which is
    worse than today and would mean reverting the default.

## Judgment, not pass/fail

30. **An 8,000-character rewrite holds the panel ~75 s**, streaming, where it
    used to take 19 s and silently truncate. Complete-and-slow was the right
    trade, but if it reads as a hang the answer is better progress in the
    panel, not a shorter budget.
31. **VoiceOver.** Turn it on and listen. The posting code is right by
    construction — `.announcementRequested` against `NSApp`, `.high` — but
    whether it is audible, and whether `.high` is too insistent for a routine
    `success`, needs a human.
32. **`Expand` on a short sentence.** It has never worked: the 3× output guard
    refused every honest expansion. With the guard gone it should now produce
    something several times longer than the source.
