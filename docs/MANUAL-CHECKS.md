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

## Needs a second app

4. **EVE-010 end to end.** Put a sentinel string on the clipboard. Select
   *different* text in the source app, trigger a rewrite that lands in
   `heldForManualCopy`, press ⌘C at the panel, read the clipboard. Expect the
   rewrite. Before the fix this gave you the source app's own selection,
   because its Copy ran after ours. Both halves are proven separately; the join
   is not.
5. **Key returns to the source app after dismiss.** Caret keeps blinking in the
   source app once the panel goes. `orderOut` resigning key is standard AppKit
   and was not tested; if it is wrong this is visible immediately.
6. **The event tap under Everest's own signature.** Tap creation is
   signature-keyed. Open the style picker, press `3`, and confirm no `3`
   appears in the source app. If `tapCreate` returns nil the picker silently
   degrades to the old leaking behaviour — which is why "capture before showing
   the picker" stays in `Overlay/AGENTS.md`.
7. **Chord still held during clipboard fallback.** `onKeyDown` fires while the
   hotkey is physically down, and capture rung 9 posts a synthetic ⌘C. Confirm
   a clipboard-fallback target (a terminal, a PDF) still captures with the
   chord held. If not, `onKeyUp` is the fix.

## Google Docs — needs a real signed-in document

8. Select a paragraph, hotkey → `.copiedOnly`, not a refusal.
9. Then Gmail **in the same window, within ten minutes** → in place, not
   copy-only. This is the `StrategyCache` guard: one Docs capture must not make
   ordinary Chrome text take the clipboard path.
10. Doc with nothing selected → the `.nothingCaptured` sentence, which names
    Google Docs.
11. Copy a sentinel, rewrite in Docs, confirm the sentinel comes back.
12. **IME composition.** Docs' hidden input is empty at rest but holds text
    mid-composition, which makes it report a non-zero character count and can
    restore the old `.noSelection` refusal. Harmless — a refusal, never a wrong
    rewrite — but it reads as flakiness.
13. A deliberately slow or huge selection, against a real app rather than a
    fake, to exercise the late-copy path.

## Judgment, not pass/fail

14. **An 8,000-character rewrite holds the panel ~75 s**, streaming, where it
    used to take 19 s and silently truncate. Complete-and-slow was the right
    trade, but if it reads as a hang the answer is better progress in the
    panel, not a shorter budget.
15. **VoiceOver.** Turn it on and listen. The posting code is right by
    construction — `.announcementRequested` against `NSApp`, `.high` — but
    whether it is audible, and whether `.high` is too insistent for a routine
    `success`, needs a human.
16. **`Expand` on a short sentence.** It has never worked: the 3× output guard
    refused every honest expansion. With the guard gone it should now produce
    something several times longer than the source.
