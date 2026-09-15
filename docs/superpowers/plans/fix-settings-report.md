# Settings, onboarding and menu — report

**AppCore: 65 tests, all green.** Baseline when I started was 35; I added 25,
other agents added the rest. Every app-target file is `swiftc -parse` only —
see *Not type-checked*.

Organised per bug, for one commit each. Files listed are the files that commit
should stage.

---

## 1. Prompts — everything editable

**Files:** `AppCore/SettingsEdits.swift`, `AppCoreTests/SettingsModelTests.swift`,
`Settings/SettingsView.swift`

**Root cause.** Two different things. The **Quick Improve** section had one
field. The **Styles** section already had name and subtitle fields, but bound
raw — no `PresetEdit`, no draft — so a style name could be blanked, and
`StylePickerView` uses `preset.name` as both row label and `accessibilityLabel`.
A blank name is a row you can only pick by counting and a screen reader
announces as nothing.

**Fix.** `InstructionField` → `PresetField`, taking its rule as a parameter
because the three fields fail differently. Styles' name and subtitle now go
through `PresetEdit`. `safetyFrame` untouched and still unreachable.

**Reversal, on your recorded decision.** I built Quick Improve's name and
subtitle fields, then found `quickImprove` has no picker row so those two
strings render nowhere. I flagged it; `QUESTIONS-FOR-PRATIK.md` now records
them as removed. **I have removed them.** `PresetEdit.name`/`.subtitle` stay —
Styles uses both.

**Also:** `PresetField` re-syncs its draft when the value moves from outside,
or "Reset to default" leaves every touched field showing what was discarded.

**Behaviours:** a preset name cannot be blanked; a subtitle may be emptied,
unlike its name.

## 2. Settings did nothing from the menu bar

**Files:** `App/EverestApp.swift`, `App/AppDelegate.swift`, `App/AGENTS.md`

**Root cause — measured, not inferred.** Activation was already there, so that
was not it. I built a throwaway `LSUIElement` SwiftUI app with a `Settings`
scene and probed macOS 26.6.2 (25G83):

```
NSApp class: AppKitApplication
NSApp.responds(showSettingsWindow:):     false
NSApp.responds(showPreferencesWindow:):  false
sendAction(showSettingsWindow:) returned: true
windows after sendAction: []
```

The selector does not exist — not on `NSApplication`, not on SwiftUI's
`AppKitApplication` — and `sendAction` **returns `true` anyway**, so the call
site saw success while no window was created. `⌘,` kept working because it is a
main-menu key equivalent resolved by `performKeyEquivalent` whenever one of
Everest's windows is key: a different path, which is why the two disagreed.

**Fix.** `@Environment(\.openSettings)`, handed to the delegate from the scene
body (which runs before `applicationDidFinishLaunching`, so it is always set).

**A second measurement made the ordering load-bearing:**

```
openSettings() with NO activate:  active=false frontmost=com.google.Chrome
                                  windows=["Probe2 Settings|key=false|visible=true"]
activate + openSettings():        active=true  frontmost=<probe>
                                  windows=["Probe2 Settings|key=true|visible=true"]
```

Without activating, the window opens *behind* the app the user came from and
never takes key — indistinguishable from nothing happening.

**No unit test.** Wiring: one assignment and two calls, no branch. Evidence is
the probe.

## 3. Show Everest in ⌘Tab

**Files:** `AppCore/AppPresence.swift`, `AppCoreTests/AppPresenceTests.swift`,
`App/AppDelegate.swift`, `Settings/SettingsView.swift`

**Root cause.** Missing preference, not a bug. Measured: launch pins to
`.accessory` under `LSUIElement`; `setActivationPolicy` flips both ways at
runtime and sticks. So the preference **must** be re-applied at launch or it
silently resets overnight and reads as broken rather than unset.

There is no ⌘Tab without a Dock icon — ⌘Tab membership *is* `.regular`. The
switch says "Show Everest in the Dock and app switcher" and explains why.

Kept out of `AppSettings` (that is `RewriteCore`'s, and out of scope); own
`UserDefaults`, as `ShortcutNotice` does.

**Behaviours:** the preference is re-applied at launch; flipping it moves the
policy immediately, both directions.

## 4. Model radio buttons were not selectable

**Files:** `AppCore/ModelSettingsModel.swift`,
`AppCoreTests/SettingsModelTests.swift`, `Settings/SettingsView.swift`,
`Settings/OnboardingView.swift`

**Root cause.** The circle was an `Image` with `.accessibilityHidden(true)` — a
picture of a radio button — and only a separate "Use" button moved `engineID`.

**Fix.** The row is a plain-styled `Button` with `.accessibilityLabel` and
`.accessibilityAddTraits(.isSelected)`. `Row.isSelected` moved into AppCore;
`select(_:)` is the only mover.

**Knock-on:** `OnboardingView` set `engineID` directly, which would have left
the Model tab's radio on the model just replaced. Now calls `models.select`.
That made three `settings` parameters dead (`OnboardingView`, `ModelTab`,
`GeneralTab` — the last already dead before I started); all removed per §1.

**Behaviour:** choosing a row selects it, and the mark follows the choice.

## 5. Show shortcuts in the menu

**Files:** `AppCore/MenuCommand.swift`, `AppCoreTests/MenuCommandTests.swift`,
`App/StatusItemController.swift`, `App/AppDelegate.swift`, `App/AGENTS.md`

**Root cause.** Not a defect — your no-`keyEquivalent` reasoning is right and I
kept it. The menu simply offered no other way to discover the binding.

**Fix.** `NSMenuItemBadge(string:)` (macOS 14+, verified in the SDK headers),
refreshed in `menuWillOpen` from `KeyboardShortcuts.getShortcut(for:)`. A badge
is non-interactive and visually distinct from a key equivalent, which is
honest: it reports a global hotkey rather than claiming the menu runs it.

**Deviation, with a reason.** Shortcut *formatting* did not go into AppCore.
`KeyboardShortcuts` renders key codes through `UCKeyTranslate` against the
**active keyboard layout** — AppCore would be wrong on AZERTY, and a second
renderer could disagree with the Settings recorder about the same binding,
which is the stale-copy failure that banned `keyEquivalent`. The library
already emits canonical `⌃⌥⇧⌘` order (I read `ks_symbolicRepresentation`).
What went to AppCore is the decision: `MenuCommand.hotkey` is `nil` for
Settings, Setup Guide and Quit, because `⌘,` and `⌘Q` work only while an
Everest window is key and this menu is only ever read over another app.

**Behaviour:** only the two global hotkeys are labelled.

---

## 6. Onboarding could not download the default model *(first-run blocker)*

**Files:** `AppCore/ModelSettingsModel.swift`,
`AppCoreTests/SettingsModelTests.swift`, `Settings/OnboardingView.swift`,
`Settings/SettingsView.swift`

**Root cause.** The step keyed everything off selection. `engineID` defaults to
`.qwen4B`, so on a new Mac the selected model is the *absent* one: the row read
"In use", was disabled, and the step never rendered `availability`, so nothing
said 2.3 GB had yet to arrive. No way forward from the one screen whose job is
getting a model onto disk.

**Fix.** `Row.needsDownload` and `Row.installSummary` in AppCore — selection
and install state as separate facts, one source, both views rendering them.
Onboarding offers Download (or "Use and download") keyed on `needsDownload`,
never on selection. Settings' Model tab uses the same two properties, which
also removed its duplicated private `status`.

**Behaviour:** a row carries its install state as well as its selection, so the
model in use can still be downloaded.

## 7. A failed download was silent everywhere *(first-run blocker)*

**Files:** `AppCore/ModelSettingsModel.swift`,
`AppCoreTests/SettingsModelTests.swift`, `Settings/OnboardingView.swift`,
`Settings/SettingsView.swift`

**Root cause.** Both call sites used `try?` and `ModelSettingsModel` published
no error. The bar vanished, the status was unchanged, and nothing separated
"finished" from "gave up", so the user retried the same failure forever.

**Fix.** `download` **no longer throws**. The error's only consumer is a label,
and a recorded failure is one a caller cannot forget to show —
`downloadFailure[EngineID]`, cleared on retry, rendered red on the row in both
screens. Structural rather than disciplinary.

**Behaviour:** a failed download says why on the row that failed, and a retry
clears the message.

**Left alone, flagged:** `delete` still uses `try?` at both call sites, so a
filesystem failure there is silent in the same way. Same shape, different bug;
say the word and it is a small change.

## 8. Excluded apps could never be removed

**Files:** `AppCore/SettingsEdits.swift`,
`AppCoreTests/SettingsModelTests.swift`, `Settings/SettingsView.swift`

**Root cause.** `.onDelete` is a `List` gesture and does nothing in a macOS
`Form` — which `Everest/Settings/AGENTS.md` already recorded for the Styles
list, but the note never reached the Privacy list. Worse here, because
`CaptureFailure.message(for: .excludedApp)` tells the user to come and remove
the entry. The app instructed an action it had not implemented.

**Fix.** `ExclusionEdit.remove`, by identity and case-insensitively to match
`add` and `SelectionCoordinator.isExcluded`, plus an explicit per-row button.
By identity so no view holds an index into an array it is mutating.

**Behaviour:** an excluded bundle id can be removed, matching the same way
adding does.

## 9. The panel hung forever on a stream that produced nothing

**Files:** `AppCore/RewriteCoordinator.swift`,
`AppCoreTests/RewriteCoordinatorTests.swift`, `AppCore/AGENTS.md`

**Root cause.** `guard let finished else { return }` assumed "no `.finished`"
meant a newer generation had taken over — but the generation check immediately
above has already proved this transaction is current. So a stream that stopped
for any other reason returned silently and left the panel on "Rewriting": no
terminal state, no auto-dismiss, force-quit the only way out.

This is the hang both auditors traced through the Settings test box. That
trigger is `EngineFactory`'s shared engine; **the hang is not**, and it is now
impossible whatever ends a stream early.

**Behaviour:** a stream that ends without a rewrite still reaches a terminal
state.

## 10. Escape during a download did not stop it

**Files:** `AppCore/RewriteCoordinator.swift`, `AppCoreTests/Harness.swift`,
`AppCoreTests/RewriteCoordinatorTests.swift`, `AppCore/AGENTS.md`

**Root cause.** The prepare-progress loop had no generation check and nothing
cancelled the task behind it. A user who pressed Escape four minutes into a
2.3 GB fetch got the panel dismissed and then **re-presented by the next
percentage** — after teardown had released the key monitors, so the panel that
came back could not be closed with Escape. The download continued.

**Fix.** `prepare` takes the generation, guards the loop, and cancels the task.
Needed a gated `prepare` in `StubEngine` to drive it.

**Behaviour:** escape during a download stops it, and no later percentage
re-opens the panel. This one reproduced as a real assertion failure in RED.

## 11. Superseded transaction still writes — **not changed, recorded instead**

**Files:** `AppCore/AGENTS.md` (one line)

The reorder was a no-op: there is **no suspension point** between the existing
`guard mine == generation` and the `apply` hop (`OutputValidator.validate` is
pure and synchronous), so a second guard could never observe anything
different. The window that does exist is *inside* the `MainActor.run` hop —
another task bumps `generation` while `apply` is queued or running — and
reordering cannot reach it.

**I first gave the wrong reason for declining** ("I cannot force the race in a
test"). You corrected it and you are right: the Iron Law wants a test of the
*decision*, and an `applyIfCurrent(_:generation:)` helper reading a
`Mutex<Int>` is directly testable — set generation 5, call with 4, assert no
write — with no interleaving needed. Untestability was never the blocker and I
will not carry that reasoning forward.

**The real reason, which is yours and which I agree with:** revalidation
already prevents the unrecoverable *wrong-target* write. What remains is an
unwanted-but-correct write that ⌘Z undoes, and that is not worth changing the
coordinator's core concurrency invariant. Recorded as known and bounded in
`AppCore/AGENTS.md`; on round 2's interaction list.

## 12. Every displayed shortcut now comes from the live binding (EVE-007)

**Files:** `AppCore/ShortcutCopy.swift`, `AppCore/ShortcutNotice.swift`,
`AppCoreTests/ShortcutCopyTests.swift`, `Settings/OnboardingView.swift`,
`Settings/SettingsView.swift`, `App/AppDelegate.swift`, `App/EverestApp.swift`,
`AppCore/RewriteCoordinator.swift`, `AppCore/SettingsEdits.swift`

**Root cause.** Your default change was right; the copy did not follow it.
Onboarding said "press ⌘I" — a dead key — and both the onboarding note and the
Settings help text asserted flatly that Everest uses ⌘I and that it is Italic,
which is now simply false.

**Fix, architectural, and written into all three `AGENTS.md`:** no glyph is
written down anywhere. `ShortcutCopy.tryItInstruction` builds the sentence from
the live value and **changes shape** when nothing is bound, rather than leaving
"press ." on the one screen that teaches the shortcut. The Italic claim became
`ShortcutNotice.caution(for:)`, shown only when the binding actually collides.

`caution` is deliberately **not** gated on having been said once, unlike
`warning`: the alert interrupts a launch so it must fire once, but the help
text describes the box the user is looking at, so sharing the gate would blank
it permanently after the first launch.

Both screens re-read on the 1-second poll they already run, so re-recording a
binding cannot strand them.

Comments in `RewriteCoordinator` and `SettingsEdits` no longer name chords. The
two remaining `⌘I` literals — the launch alert's title and
`ShortcutNotice.caution`'s sentence — are correct by construction: both appear
only when `shadowsItalic` is true, which is exactly `⌘I`.

**Behaviours:** the instruction names the bound shortcut; with none bound it
says where to set one; the help text keeps saying a shortcut collides after the
alert has been dismissed.

## 13. The 30B model was offered on Macs that cannot run it (EVE-008)

**Files:** `AppCore/ModelSettingsModel.swift`,
`AppCoreTests/SettingsModelTests.swift`, `Settings/SettingsView.swift`,
`Settings/OnboardingView.swift`

**Root cause.** `ModelCatalog` lists it unconditionally and nothing measured
memory.

**Fix.** `Row.fitsInMemory`, from injected `ProcessInfo.physicalMemory`,
requiring the weights plus **4 GB** of headroom for the OS, the app and the KV
cache — a fixed margin, not a ratio, because what the rest of the system needs
does not scale with the model. A 16 GB Mac fails (needs ~21.2 GB); 24 GB passes,
which matches root `AGENTS.md`'s "needs 18-20 GB resident".

Shown with the reason, not hidden, and the gate takes precedence over install
state so it can never say "Installed" for a model that cannot run.

**Behaviour:** a model too large for this Mac is shown with the reason.

## 14. Onboarding was gated on permission, not completion (EVE-013)

**Files:** `AppCore/OnboardingModel.swift`,
`AppCoreTests/OnboardingModelTests.swift`, `App/AppDelegate.swift`,
`AppCore/AGENTS.md`

**Root cause.** The launch check read `isAccessibilityTrusted()`. A TCC grant
cannot tell you whether anyone read the capability table or chose an engine, so
whoever granted Accessibility before opening the guide was counted as set up
and never saw the model step.

**Fix, architectural, with the why recorded:** completion is stored separately
from the permission, and the step is persisted too so closing the window
resumes rather than restarts. Only "Done" marks complete; the close button
deliberately does not.

**This exposed a real test-hygiene bug.** The two existing `OnboardingModel`
tests used the default `.standard` store, so once `advance()` began persisting,
they wrote into real defaults and handed each other a model starting halfway
through. Both now inject a throwaway suite. I also cleaned the keys that leaked
into `com.apple.dt.xctest.tool` during the RED runs — the app's own domain was
never touched.

**Behaviours:** setup is finished when the user finishes it, not when the
permission is granted; a guide closed midway resumes where it stopped.

## 15. The Privacy tab's central claim was false

**Files:** `AppCore/PrivacyCopy.swift`, `AppCoreTests/PrivacyCopyTests.swift`,
`Settings/SettingsView.swift`

**Root cause.** It answered "where does your text go?" with "Nowhere." I
verified your research against the code: `NSPasteboard.general` is written in
`PasteboardTransaction` (the synthetic ⌘C and the ⌘V) and in
`AppDelegate.copyToPasteboard` — three paths — and the general pasteboard is
Handoff-eligible.

**Fix: the claim, not the behaviour**, as you specified. The strong half stays
loud and first (local model, nothing to a server, works offline); the clipboard
exception is stated plainly in its own paragraph, not as an asterisk; it names
Handoff, says the sync is to the user's **own devices** and encrypted, says no
app can opt out, and gives the only real remedy — System Settings ▸ General.
Pinned by a test, like `exclusionCaveat`.

## 16. A truncated generation had no words of its own

**Files:** `AppCore/EngineFailure.swift`,
`AppCoreTests/RewriteCoordinatorTests.swift`

Handed over from `audit-correctness`. `GenerationError.truncated` fell through
to the generic sentence, which is not wrong but is unhelpful twice over: "try
again, or pick a different model" invites repeating an attempt that hits the
same ceiling on the same passage, and it never says the document was left
alone. `GenerationError.truncated.message` already said both and nothing read
it.

Routed on **both** surfaces — `reason(for:)` for the Model tab's test box and
`state(for:)` for the panel — as `.error`, not `.refused`: the model did not
decline, it ran out of room, and blaming it for an arithmetic limit this app
set would send the user hunting a better model instead of a shorter passage.

I did not extend `ValidationFailure`, so the no-`default` switch in
`ValidationFailure+Message.swift` is untouched.

**Behaviour:** a truncated generation is reported in its own words, on the
panel and in the test box.

## 17. F4 — a hotkey press blanked the Settings test box

**Files:** `AppCore/ModelSettingsModel.swift`,
`AppCoreTests/SettingsModelTests.swift`, `AppCore/AGENTS.md`

Round-2 finding, and the mirror of §9 with the same cause one level up.
`runTest` clears `testOutput` and `testFailure` at the top — correct, a new
run must not show the old answer — then returned setting neither when the
stream produced nothing. The view fell through to its "The rewrite appears
here." placeholder, so a user who pressed the hotkey mid-test came back to
Settings and found the test silently reset.

The way in is the shared memoised engine and its single `TransactionBox`: a
rewrite started anywhere cancels this stream. Same silent class as the `try?`
downloads, where the error's only consumer was a label.

The message names the interruption as a general truth rather than a claim
about this particular run, because any early end lands in the same branch and
only the interruption is worth explaining.

`RewriteCoordinator.swift` untouched, per your scope note.

**Budget:** this needed a line and `AppCore/AGENTS.md` was at 88 of 90, so it
bought one. I cut the `physicalMemory` row from the seams table. Root §0
requires a row per seam **protocol** whose production conformer could be
missing silently — the `SystemProbing` failure it was written for. A defaulted
`UInt64` parameter cannot go missing, so that row was the weakest line in the
file. Now 89. Say if you would rather have it back and I will find another.

**Behaviour:** a test run that produces nothing says so, rather than resetting
to the placeholder.

## 18. The panel and the test box disagreed about errors

**Files:** `AppCore/EngineFailure.swift`,
`AppCoreTests/RewriteCoordinatorTests.swift`

Round-2 finding. `reason(for:)` had a specific sentence for
`readyMarkerWithoutWeights` — with a comment calling the generic fallback
"wrong twice here" — and `state(for:)` had no branch for it at all. `state` is
the **panel**, so every hotkey press got the generic sentence; the one case
with real advice was the case that almost never showed it. `GenerationError`
had arrived the same way in §16 and needed adding to both by hand.

**Fixed as the class, not the instance**, which is what you asked for.
`state(for:)` now derives its words from `reason(for:)`, so there is one
sentence table and the next error added cannot reach one surface only. All
`state` decides is `.refused` versus `.error`.

The test is over the class too — a list of every error type, asserting the two
surfaces agree on each. A new case is covered by adding one line to the list.
A second test pins the refusal split, which `state` no longer gets for free
now that it carries no sentences: only Apple's guardrail is the model
declining, and calling a missing download or an exhausted budget a refusal
sends the user to reword writing that was never the problem.

**Behaviours:** the panel and the test box never disagree about an error; only
Apple's guardrail is reported as a refusal.

## 19. Stale justification for the capture-before-picker guard

**Files:** `AppCoreTests/RewriteCoordinatorTests.swift`,
`AppCoreTests/Harness.swift`

The file header still said a global monitor cannot consume the picker's digit
and that **"Nothing in `Overlay` can prevent this"**. The `CGEventTap` does
prevent it now, so the file explaining why capture must precede the picker
gave a reason that was no longer true.

Guard and test unchanged; only the justification. The honest version is the
one already in `RewriteCoordinator`: the tap consumes, but tap creation is
signature-keyed and `tapCreate` returns nil without the grant — so the
ordering is not redundant with the tap, it is what the tap falls back to.

**You named one instance; there were three.** `Harness.swift:21` and `:132`
carried the same claim, and both are load-bearing comments on the doubles that
make the ordering assertable. Swept rather than spot-fixed.

## 20. The generation token was never bound to its transaction

**Files:** `AppCore/RewriteCoordinator.swift`,
`AppCoreTests/RewriteCoordinatorTests.swift`, `AppCore/AGENTS.md`

Reproduced exactly as you described. `run` sampled `generation` on entry,
which is *after* `quickImprove` has already suspended on the settings read, so
a second press in that window let the first resume and adopt the **newer**
token. Both transactions then held one generation, every guard compared it to
itself, and both reached the write. Two hotkey presses — no picker, no cancel.

**Fixed by binding, not by adding guards.** `begin()` now reads `generation`
once, before its first suspension, and returns a `Transaction` carrying it.
`run` takes the transaction and refuses at entry if the token is stale —
before it touches `active`, which a stale transaction would otherwise
overwrite, leaving the next supersede cancelling the wrong engine. `pending`
carries its token too, so both doors close together: a resurrected snapshot is
refused on its own generation rather than stamped with whatever is current.
The catch path in `begin` was re-reading `generation` for its `autoDismiss`
too; that is bound now as well.

**RED was a real double write**, not a compile error: `recorder.applied` held
`"rewritten"` from a transaction that had already been superseded. I widened
`begin` and `run` to internal first so the harness could bind a token and then
supersede it, which is the decision under test — no scheduler race needed.

**`TransactionBox` is no longer what prevents the second write.** It was the
accidental containment, and only while both presses resolved the same
`EngineID`; `TargetValidator` goes back to being defence in depth. The
"known and bounded" note in `AppCore/AGENTS.md` is **removed, not softened** —
its premise was that the invariant did not hold, and now it does.

**Behaviour:** a transaction superseded before it runs never reaches the
document.

## 21. `pending` was never proved cleared

**Files:** `AppCore/RewriteCoordinator.swift` (access only),
`AppCoreTests/RewriteCoordinatorTests.swift`

**Answering your question about whether this dissolves: the harm changes
shape, the missing test does not.** With the token carried in `pending`, a
stale snapshot refuses itself, so deleting `pending = nil` no longer produces
a wrong-target write. What remains is root §6 — only the current
transaction's original in memory, because more is an undeclared history of
the user's private selections. That is reason enough on its own and it was
unpinned, so it now has its own test asserting `pending` is released on
supersede. The audit item closes as a memory guard, not as a write guard.

## 22. Two test-quality items

**Files:** `AppCoreTests/RewriteCoordinatorTests.swift`

- **The vacuous `drop(while:)`.** `drop(while: { $0 != "hide" })` returns an
  *empty* collection when "hide" is absent, so removing `panel.dismiss()` left
  the assertion passing. Added the positive control root §1 now requires.
  Proved by mutation: with `dismiss` removed the test fails on
  `log.entries.contains("hide")`, which it previously sailed through.
- **The stale whitespace comment.** It said `"   "` "would be written".
  `validate` now refuses anything with no non-whitespace character, pinned by
  `outputValidatorValidateRejectsWhitespaceOnlyOutput`. Verified against the
  code before editing rather than taking the report's word.

**Items 3 and 4 are not mine.** `coalescer`, `clock.cancel()` and
`announcedKind` are all in `Overlay/FloatingPanelController.swift:34-63`, not
AppCore. I have not touched them — they need dispatching to whoever owns
`Overlay`.

## 23. Auto-replace and clipboard-history settings — **part landed, part blocked**

**Files so far:** `AppCore/ReplacementCopy.swift`,
`AppCoreTests/ReplacementCopyTests.swift`, `AppCore/AGENTS.md`

Two settings from Pratik: *Replace automatically* (post the paste rather than
telling the user to press ⌘V) and *Keep rewrites out of clipboard history*
(mark the write `org.nspasteboard.TransientType`), both defaulting ON.

**Landed: the copy, pinned.** `ReplacementCopy.historyCaveat` states the
honour-system part plainly — `TransientType` is a convention between apps, not
a macOS rule, and a manager ignoring it still records. It also avoids implying
the rewrite skips the clipboard, because it does not and usually cannot: the
clipboard *is* how a rewrite reaches an app Accessibility cannot write to.

`ReplacementCopy.retrievalNote(autoPaste:keepOutOfHistory:)` is **conditional**
— non-nil only when both are on, which is the only combination leaving the
rewrite nowhere but the document. Against the other three it would warn about
nothing (the text is on the clipboard to paste, or in the manager's history),
and a caution that fires when nothing is at stake is one people learn to skip.

**Blocked, and why:**

- **The two booleans need `AppSettings`**, which is `RewriteCore` —
  `audit-correctness`' per `docs/OWNERSHIP.md`. Carve-out requested. I argued
  for `AppSettings` rather than a workaround because these are exactly
  `excludedBundleIDs`: read fresh, passed as a parameter. Putting them
  elsewhere would make one rule look like three.
- **The success outcome of an auto-paste is undecided.** `.copiedOnly` carries
  a promise — text is on the clipboard, user must paste — and
  `PanelOutcome.state(for:)` maps every cause to a state telling them to go
  and paste. If a successful auto-paste returns `.copiedOnly`, the panel
  instructs the user to do the thing that just happened. Proposed a `.pasted`
  case to `fix-docs`, whose file it is; my switch has no `default`, so a new
  case is a compile error here rather than a silent fall-through.

**Not decided by me:** whether auto-paste should be refused for some copy-only
causes. Posting ⌘V sends text wherever focus now is, which is TextBridge's
revalidation call — but if it is refused for some, the panel needs different
words, and that is mine.

## 24. Three smaller ones

- **The practice field could not be typed in.** `TextEditor(text: .constant(…))`
  on the step that says "type something below" — the one screen that would
  prove the hotkey works could not be used to prove it. Now `@State`.
  (`Settings/OnboardingView.swift`)
- **Index-out-of-range pattern in Styles.** Delete now removes by `id`, and
  `move` guards the **source** index as well as the destination — a row closure
  outlives the array it indexes. (`Settings/SettingsView.swift`)
- **Stale comment.** `CaptureFailure`'s "Five refusals … so five sentences" is
  now six. Rewritten without a count, since a count is what went stale.
  (`AppCore/CaptureFailure.swift`)
- **Stale glyphs in comments.** Three named `⌘⇧I` as the Choose Style binding.
  Renamed to the role, as you did in `StylePickerView`, because a comment
  cannot render from the live binding the way `ShortcutCopy` makes the UI do.
  You flagged two of them; `SettingsView.swift:251` and
  `Settings/AGENTS.md:17` were a third and fourth you had not spotted, and the
  `SettingsEdits.swift` one was already fixed. (`SettingsModelTests.swift`,
  `Settings/SettingsView.swift`, `Settings/AGENTS.md`)
- **Argument-order build break.** `OnboardingView` now declares `finish`
  last, matching the call site's grouping. Memberwise init order; a
  `swiftc -parse` pass cannot see it. (`Settings/OnboardingView.swift`)

---

## Evidence

Real RED per behaviour. Four reproduced as assertion failures rather than
missing symbols — bug 10 (`afterHide.contains { … } == false`), bug 9
(`last?.kind == .error`), and both EVE-013 tests, one of which broke an
existing test and exposed the `.standard`-store leak.

**Final:**

```
✔ Test run with 65 tests in 1 suite passed after 0.038 seconds.
```

**§23 mutations**, on a copy: dropping the honour-system admission from
`historyCaveat` failed the overclaim test; making `retrievalNote`
unconditional failed the conditional test on all three of the combinations
that must stay silent.

**Round 2 generation work** (§20-22), mutations on a copy: re-sampling
`generation` in `run` instead of carrying it failed the supersession test;
dropping `pending = nil` failed the §6 release test; removing
`panel.dismiss()` failed the newly-added positive control. All three caught.

**Round 2 mutations** (§17-18), on copies. Restoring `runTest`'s bare `return`
failed the test-box test. Then, for `EngineFailure`, two mutations run
separately to check the two new tests are not redundant: reintroducing the
independent lookup in `state(for:)` failed "never disagree" and left the
refusal test green; widening the refusal predicate to any `AppleEngineError`
failed the refusal test and left "never disagree" green. Orthogonal, which is
what justifies keeping both.

**Mutation, on a copy at `/tmp/ev-mut2`, never the shared tree.** Compile-error
RED proves a symbol was absent, not that assertions bite, so eleven mutations
went in: memory gate always passes; install state inferred from selection
again; download failure swallowed; hardcoded glyph restored; caution folded
back into the once-gate; completion inferred from the permission; removal made
case-sensitive; prepare's generation guard dropped; empty stream returns
silently; privacy copy reverted to "Nowhere."; and (batch 1) `start()` no-op,
`MenuCommand.settings` given a hotkey, `select` not moving the mark, name and
subtitle rules swapped.

A twelfth, run separately, removed the `GenerationError` branch from both
`reason(for:)` and `state(for:)`; the truncation test failed on both surfaces.

**Every one was caught by the test that owns the behaviour.** One caveat worth
recording: my first caution-gate mutation read `UserDefaults.standard` while
the test injects a suite, so it proved nothing. I rebuilt it to model the real
regression (`caution` sharing `markWarned`'s flag) and it failed correctly:

```
✘ "the help text keeps saying a shortcut collides after the launch alert has
   been dismissed" — ShortcutCopyTests.swift:59: ShortcutNotice.caution(for: italic) != nil
```

## Not type-checked — you need to build these

`KeyboardShortcuts` is not in the SwiftPM graph. All six parse; **none are
type-checked**: `App/AppDelegate.swift`, `App/EverestApp.swift`,
`App/StatusItemController.swift`, `App/HotkeyManager.swift`,
`Settings/SettingsView.swift`, `Settings/OnboardingView.swift`.

The batch-1 versions of these built clean at `7334547`, including both risks I
flagged (the `@MainActor` closures and the scene-body assignment). The one
thing a `swiftc -parse` pass could not see was **memberwise-init argument
order** — `OnboardingView` gained two properties in the middle of its
declaration list and the call site passed them before `finish`. Fixed by
moving `finish` last; that is the class of error to look for first if this
batch fails.

`{ PresetEdit.subtitle(from: $0) as String? }` uses an explicit cast rather
than relying on implicit optional promotion in a closure return, and is worth
a glance.

## Manual verification

- Settings from the menu bar opens a **key, frontmost** window. Proved on a
  probe app, not on Everest itself.
- ⌘Tab toggle: on → Dock icon and ⌘Tab entry without relaunch; quit, relaunch,
  both still there; off. `setActivationPolicy` is called from
  `applicationDidFinishLaunching`, which the probe did not reproduce.
- Menu badges render as trailing text and track a rebind.
- **First run end to end**, since that is what most of this batch is: fresh
  defaults, guide appears, model step offers a download for the default engine
  with its size, download succeeds, Done, guide does not return. Then the same
  with the guide closed midway — it should resume at the same step.
- Keyboard reach and VoiceOver on the model rows (plain `Button` focus ring
  under Full Keyboard Access; label should read name, blurb, install state).

## Things for you to arbitrate

Both resolved by the lead; kept here because the reasoning outlived them.

- **`AppCore/AGENTS.md` is 88 lines.** It was 62 before this batch and now
  carries `RewriteCoordinator`, `EngineFactory` and nine Settings-screen
  decisions from three agents. Every line carries a *why*, so the 60-line
  budget and the record-the-why rule were in direct tension in this one file.
  **Resolved:** root §2 now reads ≤60 per directory except `AppCore` at ≤90,
  named as the single exception. At 88, the next addition still has to cut
  something. `App/AGENTS.md` and `Settings/AGENTS.md` are both exactly 60.
- **~~`RewriteCore/AGENTS.md` is stale~~ — wrong, I was reading a tree minutes
  out of date.** `audit-correctness` had already rewritten it to describe the
  length-ratio removal correctly. Verified by the lead against the file. No
  action; noted so nobody chases it.

## Cross-agent adaptations

Not bugs of mine; noting them so they are not mistaken for scope creep.

- **`Harness.swift`:** Overlay added `PanelSurface.announce`. Added an empty
  stub matching the existing `refreshAppearance` precedent — deliberately *not*
  logged to the shared `CallLog`, which would insert an entry between every
  state and break this suite's ordering assertions.
- **`RewriteCoordinatorTests`:** `ValidationFailure.lengthRatio` was removed
  from RewriteCore (3× ceiling replaced by a decoder bound). Two assertions
  encoded the old contract. I kept the guard's intent — a rejection must never
  reach the document — and changed the input to `""`, the one thing `validate`
  still rejects. Note `clean` trims only inside the envelope, so `"   "` is a
  non-empty rewrite and *would* be written.
- I touched nothing in `Overlay/`, `TextBridge/`, `Engines/` or `RewriteCore/`,
  and nothing in `EngineFactory.swift` or `EngineFactoryTests.swift`.
  `HotkeyManager.swift` carries `rendered(_:)`, which I added before you
  claimed the file — flagged separately.
- I have run no git command since your policy message.
