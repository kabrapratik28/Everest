# UX audit — dead ends and silence

Read-only audit. No source file was changed.

Ranked by how stuck the user gets: total silence and permanent dead ends first,
then wrong remedies, then destructive affordances, then accessibility, then
copy, then cosmetic.

---

## Tier 1 — the user is stuck with nothing to act on

### 1. A failed model download says nothing at all, anywhere

`Everest/Settings/OnboardingView.swift:122` and `Everest/Settings/SettingsView.swift:170`

Both call sites are `Task { try? await models.download(row.spec) }`.
`ModelSettingsModel` publishes `testFailure` but has **no** equivalent for a
download (`EverestKit/Sources/AppCore/ModelSettingsModel.swift:25-28`), so
`try?` is the only handling a download error gets.

*Situation:* no network, VPN blocking huggingface.co, or the disk fills at
1.8 GB of 2.3 GB.
*What they see:* the progress bar advances, then disappears. The status line
still reads "2.3 GB to download". Nothing else changes.
*What they do next:* press Download again.
*Why it fails:* it fails the same way, silently, forever. Nothing in the app
ever names the network, the disk, or the repository. This is the worst outcome
in the product: the user cannot distinguish "not started", "failed" and
"finished".

### 2. Onboarding cannot download the default model

`Everest/Settings/OnboardingView.swift:120-124`

```
Button(settings.engineID == row.spec.id ? "In use" : "Use this") { … }
    .disabled(settings.engineID == row.spec.id)
```

`AppSettings.engineID` defaults to `.qwen4B`
(`EverestKit/Sources/RewriteCore/Settings.swift:42`), so on first run the
Qwen3 4B row already reads **"In use"** and its only button is **disabled**.

*Situation:* brand-new user on the Model step.
*What they see:* three models. The recommended one is labelled "In use" and
cannot be clicked. No size, no "not installed", no availability at all — the
step renders `displayName` and `blurb` only and never touches `row.availability`,
which it fetched.
*What they do next:* reasonably conclude the default is already set up, press
Continue.
*Why it fails:* nothing is downloaded. The only clickable buttons on that step
start a **17.2 GB** download (30B) or switch to Apple Intelligence. The user's
first hotkey press then silently begins a 2.3 GB transfer (item 12).

### 3. An excluded app can never be un-excluded, and the error says it can

Message: `EverestKit/Sources/AppCore/CaptureFailure.swift:47` — "Remove it from
the excluded apps in Settings ▸ Privacy to rewrite here."
UI: `Everest/Settings/SettingsView.swift:305-306` —
`ForEach(settings.excludedBundleIDs, id: \.self) { Text($0).monospaced() }.onDelete { … }`
inside a `Form`.

`Everest/Settings/AGENTS.md:26-29` already records the finding, for the Styles
list: *"Styles reorder with explicit buttons, not `onMove`/`onDelete`. Those are
`List` affordances. In a macOS `Form` they either do nothing or want an
`EditButton`, which macOS does not have."* The Prompts tab was given explicit
buttons for exactly this reason; the Privacy tab was not. `ExclusionEdit`
(`EverestKit/Sources/AppCore/SettingsEdits.swift:57`) has `add` and no `remove`.

*Situation:* the user adds `com.apple.Notes` to try the feature out, or the
eight shipped defaults include an app they want to use.
*What they see:* a row of monospaced text with no delete control and no
selection.
*What they do next:* follow the error message to Settings ▸ Privacy and look
for a minus button.
*Why it fails:* there is none. The list is append-only. The user is locked out
of that app permanently short of editing `UserDefaults` by hand — and the
refusal message sent them there confidently.

### 4. The panel hangs on "Rewriting" forever if the Settings test box is used mid-rewrite

`EverestKit/Sources/AppCore/RewriteCoordinator.swift:155` — `guard let finished else { return }`

`EngineFactory.live(for:)` returns **the same engine instance** to both the
coordinator and `ModelSettingsModel` (`EverestKit/Sources/AppCore/EngineFactory.swift:85-93`),
and `TransactionBox.begin` cancels whatever task it replaces
(`EverestKit/Sources/Engines/TransactionBox.swift:22-28`). `MLXEngine.stream`
catches `CancellationError` and calls `continuation.finish()` **without**
yielding `.finished` (`EverestKit/Sources/Engines/MLXEngine.swift:128-130`).

*Situation:* a rewrite is streaming; the user opens Settings ▸ Model and clicks
"Rewrite the sample".
*What they see:* the floating panel freezes on "Rewriting" with a spinner. It
has `autoDismissAfter == nil` (`PanelState.swift:136`) and `generation` was
never bumped, so nothing will ever move it.
*What they do next:* wait, then eventually press Escape.
*Why it fails:* it does not fail visibly — but nothing tells them the rewrite
is dead, and the same collision in reverse leaves the Settings box reading
"The rewrite appears here." forever (`ModelSettingsModel.swift:133`, the same
`guard let finished else { return }` with neither `testOutput` nor
`testFailure` set).

### 5. Nothing appears on screen while the selection is being read

`EverestKit/Sources/AppCore/RewriteCoordinator.swift:99-113`

`begin()` calls `capture(...)` with no panel shown first. The first `panel.show`
is `.preparing` at line 128, or the error at line 109. **`PanelState.capturing`
exists, has a symbol, words, a progress style, an auto-dismiss rule and eleven
tests, and is never shown in production** — `grep -rn "\.capturing"` over
`Sources/` returns only its own definition.

Capture is synchronous and blocks the main thread. On the accessibility-hostile
path it costs 100 ms settle (`SelectionCoordinator.swift:126`) + up to 400 ms
copy budget + 120 ms settle budget (`ClipboardSelectionAdapter.swift:36-38`) —
roughly 620 ms of nothing, on the path most likely to then fail.

*Situation:* hotkey pressed in Ghostty, a PDF, Chrome.
*What they see:* nothing for over half a second, then either a result or an
error.
*What they do next:* press the hotkey again.
*Why it fails:* the main thread is blocked, so the second press is not
delivered until the first capture finishes; then it supersedes. The user learns
that the app is unreliable. This is also the window the owner experienced as
"Google Docs silently doing nothing".

### 6. The "Try one rewrite" step names the wrong key and uses a field you cannot type in

`Everest/Settings/OnboardingView.swift:137` — "Type something below, select it, and press ⌘I."
`Everest/Settings/OnboardingView.swift:141` — `TextEditor(text: .constant("we was hoping…"))`
`Everest/Settings/OnboardingView.swift:145` — "⌘I is Italic in most apps. You can change both shortcuts in Settings ▸ General."

The defaults are `⌃⌥I` and `⌃⌥⇧I` (`Everest/App/HotkeyManager.swift:18, 23-24`).

*Situation:* the last onboarding step — the only place the app ever
demonstrates itself.
*What they see:* an instruction to type into a field bound to a constant
(nothing they type is kept), and to press a shortcut that is not bound to
anything.
*What they do next:* press ⌘I. Nothing happens.
*Why it fails:* ⌘I is not registered. The step that exists to prove the hotkey
works is the step that proves it does not. Combined with item 2, a new user
finishes onboarding with no model, no working demonstration and the wrong key
in their head.

---

## Tier 2 — the message gives an action that does not help

### 7. Accessibility revoked mid-rewrite is reported as "the text was not editable"

`EverestKit/Sources/AppCore/PanelOutcome.swift:42` maps `.noAccessibility` to
`.readOnly`; `PanelState.swift:118, 152` render that as "Copied — the text was
not editable" / "It is on the clipboard — paste it where you want it."
The real reason string — "Accessibility permission was revoked"
(`ReplacementService.swift:49`) — is **never displayed**: `copiedOnly`'s
`reason` has no reader in the panel path.

This is the surviving half of the bug that cost the owner a debugging session.
`CaptureFailure.accessibilityNotGranted` was fixed properly
(`CaptureFailure.swift:32`, including the re-add-the-entry clause); the same
condition arriving during the *write* still produces a message about
editability that never mentions permission, and auto-dismisses in 6 s.

`.rangeDerived` lands in the same state, where "not editable" is also false —
the field was editable, Everest declined to write to it.

### 8. Network and disk failures are reported as "try a different model"

`EverestKit/Sources/AppCore/EngineFailure.swift:46` — "The rewrite stopped
before it finished. Try again, or pick a different model in Settings."

`EngineFailure.reason/state` name only `AppleEngineError` and
`ModelStoreError.readyMarkerWithoutWeights`. Everything else falls to `generic`:
`URLError` from `HubModelFetcher`, a full disk, `ModelFetchError.malformedRepositoryID`,
`ModelFetchError.missingPinnedRevision`, every `MLXProducerError`.

*Situation:* no network on first run. `prepare` throws mid-download.
*What they see:* "The rewrite stopped before it finished. Try again, or pick a
different model in Settings."
*What they do next:* pick a different model.
*Why it fails:* the other local model is a 17.2 GB download over the same dead
connection. The one word that would end the session — network, disk, offline —
never appears.

### 9. "Try a shorter passage" makes the length-ratio failure more likely, not less

`EverestKit/Sources/AppCore/ValidationFailure+Message.swift:15` — "The model
returned far more text than it was given, so your selection was left alone.
Try a shorter passage, or a different style."

The check is `cleaned.count / source.count > 3.0`
(`EverestKit/Sources/RewriteCore/OutputValidator.swift:43-46`). A shorter
source shrinks the denominator, so the ratio goes **up**. The advice is
backwards.

*Situation:* the user picks the built-in **Expand** style — "Expand this with
more supporting detail and clarity" (`Presets.swift:64`) — on a one-line
selection. That style is designed to produce exactly the output this validator
rejects.
*What they do next:* select less text and try Expand again.
*Why it fails:* it fails harder. "A different style" is the only half of the
sentence that can work, and it is second.

### 10. "Select the text you want rewritten" is shown to a user who has selected text

Message: `EverestKit/Sources/AppCore/CaptureFailure.swift:36`.
Thrown at `EverestKit/Sources/TextBridge/SelectionCoordinator.swift:219` when
the focused element reports a zero-length range **and** a non-zero character
count.

The same file already documents that the focused element is often not where the
selection lives (`SelectionCoordinator.swift:209-212`: *"Chrome parks focus in
an empty `contenteditable` while Google Docs paints the document into a
canvas"*). The escalation is gated on the helper element being **empty**; a
helper element that happens to hold characters throws `.noSelection` instead
and never reaches rungs 8 or 9.

*Situation:* text visibly highlighted in a Chromium/Electron surface.
*What they see:* "Select the text you want rewritten, then press the shortcut
again."
*What they do next:* reselect and press again.
*Why it fails:* the branch is deterministic for that element, so it fails
identically every time. `CaptureError.nothingCaptured` exists precisely to
avoid this ("sends the other half of the users to reselect forever",
`TargetSnapshot.swift:121-125`) and this path does not reach it.

### 11. Escape during a download closes the panel but does not stop the download

`RewriteCoordinator.cancel()` → `supersede()` → `active?.cancel()`
(`RewriteCoordinator.swift:83-86, 116-121`). `TransactionBox` only ever holds
the task registered by `stream(_:)` (`MLXEngine.swift:138`); `prepare` is never
registered.

*Situation:* the user presses the hotkey, sees "Preparing model — 3% downloaded",
realises they are tethered, presses Escape.
*What they see:* the panel closes.
*What they do next:* nothing; they assume it stopped.
*Why it fails:* the `Task` inside `RewriteCoordinator.prepare` keeps running and
the transfer continues to completion. There is no UI anywhere that shows it —
`ModelSettingsModel.downloadProgress` is a separate object and stays empty. The
punch list's "App idling at ~22% CPU — that was the 2.3 GB model downloading"
is this, observed and misattributed.

Second-order: the progress loop at `RewriteCoordinator.swift:185-187` has **no
generation check**, so a superseded transaction's progress updates keep calling
`panel.update(.preparing(…))` over whatever the newer transaction is showing.

### 12. A 2.3 GB / 17.2 GB download starts with no size shown and nothing asked

The size exists in `ModelCatalog` (`approxBytes`) and is rendered **only** in
`Everest/Settings/SettingsView.swift:187-190`. Neither of the two places a
download actually starts shows it:

- `Everest/Settings/OnboardingView.swift:120-124` — "Use this" sets the engine
  and immediately calls `download`. The 30B row starts **17.2 GB** on one click.
  The step renders `blurb` only ("Higher quality. Larger download, more
  memory.") — no number.
- `EverestKit/Sources/AppCore/RewriteCoordinator.swift:131` — the first hotkey
  press calls `prepare`, which downloads. The panel shows "Preparing model" and
  then "3% downloaded" (`PanelState.swift:151`). No total, no byte count, no
  consent, and Escape does not stop it (item 11).

**Answer to the brief's question: no, the 2.3 GB is not explained before it
starts — not in onboarding, and not at the moment it starts.**

---

## Tier 3 — a destructive action, presented as a neutral one

### 13. "esc — Cancel" throws away the user's only copy of the rewrite

`EverestKit/Sources/Overlay/PanelState.swift:65-67` derives the hint from
`autoDismissAfter == nil`; `heldForManualCopy` is the one state where that is
true *because the panel holds the only copy*
(`PanelState.swift:130-133`). `RewriteView.swift:102` gives VoiceOver "Close
this panel". `FloatingPanelController.cancel()` → `RewriteCoordinator.cancel()`
→ `panel.dismiss()`, no confirmation, no recovery.

The state's whole design note says a **timer** must never delete the work. A
keystroke labelled "Cancel" does, and the label is the same word used in every
other terminal state where cancelling costs nothing.

### 14. In `heldForManualCopy(.clipboardTooLarge)`, the offered ⌘C destroys the thing the state exists to protect

`ReplacementService.swift:171-179` enters this state precisely because the
clipboard holds something that could not be faithfully snapshotted, so
overwriting it would be unrecoverable. The panel then says **"Copy this before
closing"** (`PanelState.swift:123`) with a `⌘C Copy` hint, and
`AppDelegate.copyToPasteboard` (`Everest/App/AppDelegate.swift:101-105`) does a
bare `clearContents()` + `setString(…)` — no `PasteboardTransaction`, no
`PasteboardBorrow`, no warning.

The cost is stated only as a trailing lowercase clause in the detail line —
"…, and your clipboard is too large to put back" — while the headline reads as
an instruction. A user following the headline destroys their unrecoverable
clipboard and is never told that is what happened.

### 15. "Delete" is greyed out with no reason, and a failed delete is silent

`Everest/Settings/SettingsView.swift:172-176` — `.disabled(!models.canDelete(row.spec))`.
`ModelDeletionError.inUse` (`ModelSettingsModel.swift:6-13`) carries a
deliberate explanation — *"the useful answer is to say which switch to make
first"* — and is **unreachable**: its only throw site sits behind the disabled
button, and the call is `Task { try? await models.delete(row.spec) }`.

*Situation:* the user wants the 2.3 GB back.
*What they see:* a greyed Delete on the model they want gone, an enabled Delete
on the one they never installed.
*What they do next:* nothing, or they guess.
*Why it fails:* the rule ("switch to another model first") is written down and
never shown. A delete that fails on disk is also swallowed by `try?`, and
`refresh()` only runs on success, so the row keeps saying "Installed".

---

## Tier 4 — accessibility of the app itself

### 16. VoiceOver is never told the panel exists

No `NSAccessibilityPostNotification` / `AccessibilityNotification` anywhere in
the tree (`grep -rn "NSAccessibility" Sources Everest` → one
`setAccessibilityLabel` on the status item). The panel is
`[.borderless, .nonactivatingPanel]` with `canBecomeKey` false in every
non-terminal state (`NSPanelSurface.swift:19-26, 59`), which is correct for
capture and means VoiceOver focus never moves to it.

`RewriteView` has good per-element labels (`RewriteView.swift:50-51, 87, 142-143`)
and `PanelState.accessibilityValue` is composed carefully — but nothing ever
*announces* them. A VoiceOver user presses the hotkey and hears nothing: not
"Rewriting", not "Replaced", not any of the twenty messages audited above, not
"Copy this before closing" on the state that holds their only copy.

This app is built on the Accessibility API. Its entire feedback channel is
currently inaudible to the users that API exists for.

### 17. A style's name can be blanked, producing an unlabelled picker row

`Everest/Settings/SettingsView.swift:221` uses a raw
`TextField("Name", text: $style.name)`.
`PresetEdit.name` (`EverestKit/Sources/AppCore/SettingsEdits.swift:26`) exists
to prevent exactly this and **has no call site** — its own doc comment says
*"Emptying it leaves a row that can only be picked by counting, is announced as
nothing, and is indistinguishable from the next empty one."* The guard was
written, tested and never wired up. (`PresetEdit.subtitle` is likewise unused;
the subtitle is the `accessibilityHint` at `StylePickerView.swift:65`.)

### Sound in this area, for the record

- **Keyboard-only operation of the panel** is complete: Escape, ⌘C, digits 1–5,
  arrows and Return are all handled through the monitors and the event tap, and
  a sixth style is reachable with the arrows (`PanelKeyMap.swift:52-72`).
- **Reduce Motion, Reduce Transparency, Increase Contrast** are all honoured and
  tested (`PanelAppearance.swift`). Sampling once per `show()` means a mid-stream
  toggle is missed; that is a documented trade and not worth changing.
- **Nothing is signalled by colour alone** anywhere I could find. Every tick,
  cross, radio and red error line has words beside it, and the capability table
  spells out "In place" / "Copy only" / "Refused"
  (`OnboardingView.swift:161-167`).
- **`CaptureFailure.accessibilityNotGranted`, `.secureField`, `.tooLong`,
  `.nothingCaptured`** and `EngineFailure.weightsMissing` all name a remedy the
  user can actually perform, and the Download button really does appear in the
  `weightsMissing` case because `prepare` clears the marker before throwing.

---

## Tier 5 — copy that claims more than the app delivers

### 18. "Nowhere." omits the clipboard round-trip

`Everest/Settings/SettingsView.swift:292-299` — *"Nowhere. Everest runs the
model on this Mac. No selection, no rewrite and no telemetry is sent anywhere,
and nothing you select or generate is written to the system log."*

Narrowly true and materially incomplete. `ClipboardSelectionAdapter.swift:7-14`
documents the exposure in its own words: *"During the synthetic ⌘C the target
app writes the selected text to the pasteboard. That write is not ours, so we
cannot mark it transient, and any clipboard history app the user runs will
record it."* Every copy-only outcome then writes the **rewrite** durably to the
pasteboard as well (`ReplacementService.swift:199`).

A user reading the Privacy tab with Raycast or Paste or Maccy running has been
told their selections stay put. Rung 9 and every `copiedOnly` puts them in a
searchable history on disk.

### 19. "Password and secure fields are refused before they are read" has a documented hole

`Everest/Settings/SettingsView.swift:300` states it flatly; the onboarding table
row reads capture "Never", replace "Refused"
(`EverestKit/Sources/AppCore/OnboardingModel.swift:99`); the exclusion caveat
(`OnboardingModel.swift:85-90`) says the subrole check *"is what protects a
password"*.

`SelectionCoordinator.swift:90-92` records the residual: *"an app that exposes
no tree at all gives us nothing to classify, so only the process-wide flag
applies there."* In that case `refuseIfSecure` is skipped (`if let focused`,
line 94) and rung 9 posts a synthetic ⌘C blind (line 139). The stated mitigation
is the exclusion list — which cannot be edited (item 3) and which the same
onboarding text tells the user is *not* the protection.

Three absolute statements ("Never", "Refused", "is what protects a password")
sitting on top of a gap the code documents. The caveat text is otherwise
excellent and does the harder half of this job well.

### 20. Stale ⌘I warnings

`Everest/Settings/SettingsView.swift:49` — "⌘I is Italic in most apps. Everest
takes it globally while it is set." Shown unconditionally, directly beneath a
recorder displaying `⌃⌥I`.
`Everest/Settings/OnboardingView.swift:145` — same claim.

Both warn about a collision the default no longer has.
`ShortcutNotice.warning(for:)` (`EverestKit/Sources/AppCore/ShortcutNotice.swift:53-57`)
gets this right — it is gated on `shadowsItalic` — and these two static strings
bypass it. Its own doc comment names the cost: *"a user who has rebound to ⌥R
is being warned about a collision that no longer exists, which teaches them
Everest's warnings are noise."*

`Everest/App/HotkeyManager.swift:5-6` also still carries the old doc comment
("`⌘I`. Shadows Italic almost everywhere") stacked above the new one.

---

## Tier 6 — cosmetic or narrow

21. **Every `copiedOnly` / `heldForManualCopy` reason is a lowercase sentence
    fragment with no remedy** — "the target would not accept the write, and your
    clipboard is too large to put back" (`ReplacementService.swift:177-179`,
    `TargetValidator.swift:52-60`). Renders as the detail line under a headline,
    starting mid-sentence. The seven `copiedOnly` reasons are never displayed at
    all (see item 7), so only the two hold reasons are user-visible.

22. **No surface in the app shows the bound hotkey except the recorder.** The
    menu deliberately carries no `keyEquivalent` (`StatusItemController.swift:53-58`,
    sound reasoning), onboarding names the wrong one, and nothing else mentions
    them. The style picker (`⌃⌥⇧I`) is never mentioned in onboarding at all —
    the menu's "Choose Style…" is its only trace.

23. **A hotkey that fails to register is indistinguishable from an app that is
    not running.** `HotkeyManager.register()` (`Everest/App/HotkeyManager.swift:41-55`)
    has no failure path to check — `KeyboardShortcuts.onKeyDown` returns Void —
    so if another app already holds `⌃⌥I`, Settings keeps displaying it as bound
    and the key does nothing forever. The onboarding "try it" step would be the
    natural place to catch this, and it is broken (item 6).

24. **`pickStyle` with a cleared `pending` is a silent no-op on a picker that
    never closes itself.** `RewriteCoordinator.swift:90` — `guard let snapshot =
    pending else { return }`. `stylePicker` has `autoDismissAfter == nil`, so a
    click landing in the window between `supersede()` clearing `pending` and the
    new state being rendered leaves the picker up and inert. Escape still works.
    Narrow race, but the failure mode is a stuck panel.

25. **`NSAlert.runModal()` during `applicationDidFinishLaunching`**
    (`Everest/App/AppDelegate.swift:113-119`) without `NSApp.activate`. Everest
    is `LSUIElement` with no Dock icon, so a modal that opens behind another
    window cannot be found or dismissed. Only reachable once the user has
    deliberately bound ⌘I, so it is rare rather than harmless.

---

## Areas that are sound

One line each, as asked.

- **Capture refusal messages** are genuinely five (six) distinct remedies, and
  the `accessibilityNotGranted` and `nothingCaptured` sentences are the best
  copy in the product.
- **`PanelOutcome`'s split** between "the world moved, try again" and "there is
  nowhere to write, it never will" is the right axis, and the `unverifiable`
  placement note is correct.
- **The style picker's key handling** — capture-before-show, the event tap armed
  only in `stylePicker`, digits/arrows/Return/Escape — is complete and closes
  the arrow-key leak the owner hit.
- **The capability table's placement** (before the model step, words as well as
  colour) and the exclusion caveat are doing the honest work the brief asks for.
- **Panel geometry, throttling, tail-following and auto-dismiss schedules** show
  no user-facing defect I could find.
