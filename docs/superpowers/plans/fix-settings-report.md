# Five Settings and menu UX bugs — report

**Status: all five done.** AppCore is green at **45 tests** (was 35; I added 6,
other agents added 4 in the same window). Every app-target file is
`swiftc -parse` only — see *Not type-checked* at the end.

---

## 1. Everything in Prompts should be editable

**Root cause.** Two different things, and the brief's framing ("only the
instruction is editable") is true of only one of them.

- The **Quick Improve** section rendered a single `InstructionField`. Name and
  subtitle had no field at all.
- The **Styles** section already had `TextField("Name")` and
  `TextField("Subtitle")`, but bound **raw** — no `PresetEdit`, no draft. A
  style name could be blanked, and `StylePickerView` uses `preset.name` as both
  the row label *and* the `accessibilityLabel`, so a blank name is a row you
  can only pick by counting and a screen reader announces as nothing.

**Fix.** `InstructionField` became `PresetField`, which takes its rule as a
parameter because the three fields fail differently. Quick Improve gained Name
and Subtitle. Styles' name and subtitle now go through `PresetEdit`.

`PromptBuilder.safetyFrame` is untouched and still unreachable from Settings.

**Also fixed while in there:** `PresetField` re-syncs its draft when the stored
value moves from outside. Without it "Reset to default" leaves every touched
field showing what the user just discarded — visible now that the section has
three fields instead of one.

> **Worth your call.** `settings.quickImprove.name` and `.subtitle` are
> rendered *nowhere* — only `StylePickerView` draws a preset's name, and it
> draws `settings.styles`, never `quickImprove`. So the two new Quick Improve
> fields are editable and persist, and nothing displays them. I built what was
> asked and am flagging it rather than quietly dropping it: either the panel
> should show which preset ran, or those two fields are decoration.

**Behaviours driven out (2)**
- a preset name cannot be blanked
- a preset subtitle may be emptied, unlike its name

## 2. Settings does nothing from the menu bar

**Root cause — confirmed by measurement, not inference.** The code already
called `NSApp.activate` before `sendAction`, so activation was never the
problem. I built a throwaway `LSUIElement` SwiftUI app with a `Settings` scene
and probed it on **macOS 26.6.2 (25G83)**:

```
NSApp class: AppKitApplication
NSApp.responds(showSettingsWindow:):     false
NSApp.responds(showPreferencesWindow:):  false
sendAction(showSettingsWindow:) returned: true
windows after sendAction: []
```

Two findings. The selector **does not exist** on macOS 26 — not on
`NSApplication`, not on SwiftUI's `AppKitApplication`. And `sendAction`
**returns `true` anyway**, so the call site saw success while no window was
ever created. That is why it failed silently rather than logging anything.

`⌘,` kept working because it is a main-menu key equivalent that
`performKeyEquivalent` resolves whenever one of Everest's own windows is key —
a different path entirely, which is why the two disagreed.

**Fix.** `@Environment(\.openSettings)`. It reads only from a SwiftUI scope, so
`EverestApp`'s scene body hands the action to the delegate; the scene body runs
before `applicationDidFinishLaunching`, so it is always set before a menu item
can be clicked.

**A second measured finding made the ordering load-bearing:**

```
after openSettings() with NO activate:
  active=false  frontmost=com.google.Chrome
  windows=["Probe2 Settings|key=false|visible=true"]

after activate + openSettings():
  active=true   frontmost=<the probe app>
  windows=["Probe2 Settings|key=true|visible=true"]
```

Without activating, the window opens *behind* the app the user came from and
never takes key — indistinguishable from nothing happening. Activate first.
Calling the action again while the window is already open is harmless, so
there is no "already showing" branch.

**No AppCore test.** This is wiring: one property assignment and two calls in
order, with no branch. Evidence is the probe above; see *Manual verification*.

## 3. Show Everest in ⌘Tab

**Root cause.** Not a bug — a missing preference. Also measured:

```
policy at launch: 1 (accessory)      # LSUIElement, as expected
setActivationPolicy(.regular)  -> true; now 0
policy after 1s: 0                    # sticks
setActivationPolicy(.accessory) -> true; now 1
```

So runtime flipping works in **both** directions and holds. The `LSUIElement`
interaction you flagged is real and is the whole design constraint: every
launch starts at `.accessory` regardless of what the user chose, so the
preference must be re-applied at launch or it silently resets overnight and
reads as broken rather than unset.

**On the Dock icon:** there is no way to have one without the other. ⌘Tab
membership *is* `.regular`, which is also what puts the icon up. So the switch
is labelled "Show Everest in the Dock and app switcher" and says so underneath
— a switch promising only ⌘Tab would deliver a Dock icon the user never asked
for and could not find the control to remove.

**Fix.** `AppCore/AppPresence.swift`, with its own `UserDefaults` (as
`ShortcutNotice` does) rather than a field on `AppSettings`: `AppSettings` is
`RewriteCore`'s, and prompts and presets have no business knowing how the app
shows itself to the window server. That also kept me out of `RewriteCore`,
which was not in scope.

**Behaviours driven out (2)**
- the preference is re-applied at launch, because LSUIElement pins every launch
  to the menu bar
- flipping the switch moves the policy immediately, in both directions

## 4. Model radio buttons are not selectable

**Root cause.** The circle was `Image(systemName:)` with
`.accessibilityHidden(true)` — a picture of a radio button — and the only
control that moved `engineID` was a separate "Use" button. The thing that
looked like the control and the thing that was the control were different
views.

**Fix.** The row is now a plain-styled `Button` over the whole label, with
`.accessibilityLabel` (name, blurb, install state) and
`.accessibilityAddTraits(.isSelected)`, so VoiceOver announces it as a selected
control rather than reading a decorative glyph. "Use" is gone. `Spacer` is
inside the button with `.contentShape(Rectangle())`, so the dead space beside
the blurb is part of the target.

`Row.isSelected` moved onto the row in `AppCore` so the mark and the setting
cannot disagree, and `select(_:)` is now the only thing that moves the engine.

**Knock-on I had to fix:** `OnboardingView` set `settings.engineID` directly.
Left alone, picking a model during onboarding would have left the Model tab's
radio pointing at the model the user just replaced. It now calls
`models.select`. That also made `OnboardingView`'s `settings` parameter dead,
and `ModelTab`'s, and `GeneralTab`'s (that last one was already dead before I
started) — all three removed per §1.

**Behaviour driven out (1)**
- choosing a model row is what selects it, and the mark follows the choice

## 5. Show the shortcuts in the menu

**Root cause.** Not a defect — the reasoning in `App/AGENTS.md` is right and I
kept it. No `keyEquivalent` was added. The gap is that the menu offered no
other way to discover the binding.

**Fix.** `NSMenuItemBadge(string:)` (macOS 14+, verified in the SDK headers) as
trailing text, refreshed in `NSMenuDelegate.menuWillOpen` from
`KeyboardShortcuts.getShortcut(for:)`. A badge is non-interactive and visually
distinct from a key equivalent, which is honest: it reports a global hotkey
rather than claiming the menu will run it.

> **One deviation from the brief, with a reason.** You asked for shortcut
> *formatting* in AppCore. I did not put it there, because AppCore cannot do it
> correctly: `KeyboardShortcuts` renders a key code through `UCKeyTranslate`
> against the **active keyboard layout**, so the same code is `I` on QWERTY and
> something else on AZERTY. A hand-rolled AppCore formatter would be wrong on
> non-US layouts, and it would be a second renderer free to disagree with the
> recorder in Settings ▸ General about the same binding — which is the exact
> stale-copy failure that banned `keyEquivalent`. The library already emits
> canonical `⌃⌥⇧⌘` order (I read `ks_symbolicRepresentation` to confirm), so
> rendering stays in the app target.
>
> What went to AppCore instead is the part that is a decision and *is* testable:
> **which commands may show a shortcut at all.** `MenuCommand.hotkey` is `nil`
> for Settings, Setup Guide and Quit — not because they are unbound, but
> because `⌘,` and `⌘Q` only work while one of Everest's own windows is key,
> and an accessory app owns no menu bar. This dropdown is only ever read *over
> another app*, where those do nothing. Printing them would advertise a
> shortcut that is dead where it is being read.

**Behaviour driven out (1)**
- only the two global hotkeys are shown in the menu; the app-menu key
  equivalents are not

---

## RED and GREEN

Baseline before any change — **35 passed**:

```
✔ Test run with 35 tests in 1 suite passed after 0.030 seconds.
```

**RED, item 1** (`swift build --target AppCoreTests`):

```
SettingsModelTests.swift:148:24: error: type 'PresetEdit' has no member 'name'
SettingsModelTests.swift:163:24: error: type 'PresetEdit' has no member 'subtitle'
```

**RED, items 3 and 5:**

```
MenuCommandTests.swift:22:13: error: cannot find 'MenuCommand' in scope
MenuCommandTests.swift:31:67: error: cannot find 'Hotkey' in scope
AppPresenceTests.swift:32:18: error: cannot find 'AppPresence' in scope
AppPresenceTests.swift:36:20: error: cannot find 'AppPresence' in scope
```

**RED, item 4** (after 3 and 5 compiled, so this file's errors surfaced):

```
SettingsModelTests.swift:106:11: error: value of type 'ModelSettingsModel' has no member 'select'
SettingsModelTests.swift:104:31: error: cannot infer key path type from context   # \.isSelected
```

**GREEN — final, whole suite:**

```
✔ Test run with 45 tests in 1 suite passed after 0.057 seconds.
```

## Mutation, on a copy

Compile-error RED proves a symbol was absent, not that the assertions bite. So
four mutations went into a **copy at `/tmp/ev-mut`** (never the shared tree),
all at once:

1. `AppPresence.start()` → no-op
2. `MenuCommand.settings.hotkey` → `.quickImprove`
3. `select(_:)` → sets `engineID` but does not move the mark
4. `PresetEdit.name` accepts blanks / `subtitle` refuses them

Every one was caught, each by the test that owns the behaviour:

```
✘ "the app-switcher preference is re-applied at launch…"  recorded an issue at
   AppPresenceTests.swift:41: recorder.applied == [.regular]
✘ "only the two global hotkeys are shown in the menu…"    recorded an issue at
   MenuCommandTests.swift:25: MenuCommand.settings.hotkey == nil
✘ "choosing a model row is what selects it…"              recorded an issue at
   SettingsModelTests.swift:109: model.rows.filter(\.isSelected).map(\.id) == [.qwen30B]
✘ "a preset name cannot be blanked"                       2 issues
✘ "a preset subtitle may be emptied, unlike its name"     1 issue
```

Five of my six tests failed under mutation; the sixth
(`flippingThePreferenceAppliesImmediately`) covers a path none of the four
mutations touched.

## Not type-checked — you need to build these

`KeyboardShortcuts` is not in the SwiftPM graph, so these are `swiftc -parse`
only. **All six parse; none are type-checked.**

- `Everest/App/AppDelegate.swift`
- `Everest/App/EverestApp.swift`
- `Everest/App/StatusItemController.swift`
- `Everest/App/HotkeyManager.swift`
- `Everest/Settings/SettingsView.swift`
- `Everest/Settings/OnboardingView.swift`

Most likely to bite, in order:

1. **Actor isolation on the two new closures.** `presentSettings` and
   `shortcutText` are declared `@MainActor` because they call
   `OpenSettingsAction.callAsFunction()` and `KeyboardShortcuts.Shortcut`'s
   `description`, both of which look MainActor-isolated. If inference disagrees,
   the annotations are the thing to change.
2. **`delegate.presentSettings = …` inside `EverestApp.body`.** A side effect in
   a scene body, and it needs the explicit `return` that is now there. It is the
   earliest scope that has the action; the alternative (reading `@Environment`
   in `init()`) also worked in the probe but relies on the default environment
   value.
3. **`{ PresetEdit.subtitle(from: $0) as String? }`** — written with the explicit
   cast rather than relying on implicit optional promotion in a closure return.

## Manual verification

- **Settings from the menu bar** opens a key, frontmost window. Proved on a
  standalone probe app, not on Everest itself.
- **⌘Tab toggle:** flip it on, confirm the Dock icon and ⌘Tab entry appear
  without a relaunch; quit and relaunch, confirm both come back. Then off.
  `setActivationPolicy` is called from `applicationDidFinishLaunching`, which
  the probe did not reproduce (it called it ~3s after launch).
- **Menu badges** render as trailing text and track a rebind: open the menu,
  re-record Quick Improve in Settings, open the menu again.
- **Keyboard reach on the model rows.** With Full Keyboard Access on, Tab should
  land on each row and Space should select it. A `.plain` button style is the
  usual answer, but the focus ring is worth an eye.
- **VoiceOver on a model row:** should read name, blurb and install state, and
  say "selected" on the current one.

## Two things to arbitrate

- **`AppCore/AGENTS.md` is 70 lines, over the 60 budget.** It was already 62
  before I touched it — another agent added an `EngineFactory` section in the
  same window. I tightened the pre-existing prose by ~4 lines and kept my own
  addition to ~12, losing no decision. Going lower means deleting someone
  else's reasoning, which is not mine to do. `Everest/App/AGENTS.md` and
  `Everest/Settings/AGENTS.md` are both exactly 60.
- **The Quick Improve name/subtitle display nothing** — see item 1.

## Not mine

Two failures during this work came from another agent's in-flight TextBridge
change and are both fixed now: `CaptureError.nothingCaptured` made
`AppCore/CaptureFailure.swift`'s switch non-exhaustive, and the same insertion
left `RewriteCoordinatorTests.swift:505` asserting on `messages[4]` after
`excludedApp` had shifted to `[5]`. I flagged both to `tdd-bridge` rather than
editing their tests; they fixed both. I touched no file in `Overlay/`,
`TextBridge/`, `Engines/` or `RewriteCore/`.
