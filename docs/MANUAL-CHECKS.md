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

11. **EVE-010 end to end, plus ⌘V in the same run.** Put a sentinel string on
   the clipboard. Select *different* text in the source app, trigger a rewrite
   that lands in `heldForManualCopy`, press ⌘C at the panel, read the
   clipboard — expect the rewrite, not the source app's own selection. **Then
   press ⌘V while the panel is still up**: it must paste. Those are the two
   halves of the same mechanism — the tap consumes ⌘C and passes everything
   else — and one keystroke checks both.
12. **With Accessibility revoked, ⌘C at the panel does nothing at all.**
   Deliberate, and the lesser of two losses: honouring it would write the
   rewrite, dismiss the panel, and let the source app's Copy land over the
   top — you would think you had saved it and the only copy would be gone.
   Refusing costs a keystroke. **The Copy button still works**, and the ⌘C
   hint is still drawn in that state, so the panel advertises a shortcut that
   will not fire. Known and left: hiding it would make `keyHints` depend on
   whether the tap is live, and a pure function of state should not.
13. **The event tap under Everest's own signature, and what happens without
   it.** Normal case: open the style picker, press `3`, confirm no `3` appears
   in the source app. **Then revoke Accessibility and repeat** — the picker
   must now do *nothing at all* on `3`, and no `3` may reach the document.
   That is the fail-closed path: previously it picked a style *and* typed into
   your text while reporting success. Escape must still close the picker, and
   the mouse must still work.
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

22. **Download and hotkey racing the same missing model — resolved by
    reading the dependency, kept only as a sanity check.** `LoadOnce`
    single-flights the *load* and nothing single-flights the *download*, but
    that turns out to be harmless and was deliberately not "fixed".
    `swift-huggingface`'s `FileLock` is `LOCK_EX | LOCK_NB` — a *non-blocking*
    flock in a retry loop — and it re-checks the cache inside the lock, so the
    bytes never transfer twice. The waiter retries on `Task.sleep`, which
    throws on cancellation, so a cancelled second caller aborts within about a
    second; and the cached-hit branch sets progress straight to complete, so
    there is no stalled spinner. Refs, so nobody re-derives it:
    `HubClient+Files.swift:518-537`. *Do, if you want confirmation:* delete the
    model, click Download, press the hotkey while it transfers, and check the
    panel neither stalls nor re-downloads.
    **Separately and plainly: the engine's `cancel()` cannot abort a transfer
    and never could** — it only cancels the generation stream. What aborts a
    download is the coordinator cancelling its own preparation task. Two
    mechanisms, not one.
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
    **Same run, second question:** restoring your clipboard is a *write*, not
    a rollback — the contents come back byte for byte, but the manager sees a
    write of your own content and may log a duplicate entry. Maccy dedupes
    consecutive identical content; others may not. Not a broken promise — the
    rewrite still never enters history — but worth knowing, and the same five
    minutes answers both.
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
33. **Do the Prompts fields now read as editable?** Only Pratik can answer
    this; it is the one item on the list whose acceptance criterion is a
    feeling. `PresetField` was a borderless `TextField` in a `Form`, which
    macOS draws flat to match System Settings — so a populated field looked
    exactly like static label text. It now has `.roundedBorder` and a
    persistent caption above it. *Do:* Settings ▸ Prompts, look at a Style
    with all three fields filled in, and say whether it is obvious you can
    type in them and obvious which is which. The caption matters as much as
    the border: the field name used to be only a placeholder, and placeholders
    disappear the moment there is content.
34. **Both replacement toggles actually do something.** Settings ▸ General ▸
    Replacing text. *Do:* with "Replace automatically" on, rewrite in a
    terminal or PDF — the rewrite should paste itself rather than telling you
    to press ⌘V. Switch it off mid-session and rewrite again *without
    relaunching*: it must go back to handing you the clipboard, because both
    flags are read per transaction and a stale capture is the failure mode
    they are written to avoid. Then check a clipboard manager (Maccy, Alfred,
    Raycast) records nothing while "Keep rewrites out of clipboard history"
    is on — and note that a manager ignoring `TransientType` is allowed to
    record anyway, which is what the caveat under the toggle says.
35. **The recorder says what the binding costs.** Settings ▸ General. With the
    `⌥R` default it should read "…will no longer type ®" as plain secondary
    text, *not* styled as the Italic caution — it is information, and the cost
    is why `⌥R` was chosen. **Then record `⌥I`:** the line should change to the
    dead-key caution about accented typing, since `⌥I` produces no character.
    **Then record `⌘R`:** the cost line must *disappear*. Measured —
    `UCKeyTranslate` reports `⌘R` as `"r"`, the same as the bare key, so a
    naive reading would claim you can no longer type `r`. That exclusion is
    the part worth eyeballing, because it is the one that would be wrong
    rather than merely absent.
