# AppCore/Settings — what the Settings and onboarding screens decide

Nothing here is shared with the transaction engine next door: that one is a
rewrite going through, this is what the user is told and allowed to change.

## Decisions

- **No glyph is ever written down.** `ShortcutCopy` builds shortcut sentences
  from the live binding, `nil` changing their shape rather than leaving a
  hole. The default moved twice — `⌘I`→`⌃⌥I`→`⌥R` — while screens went on
  saying `⌘I`: a literal is correct only until someone rebinds.
- **Selection and install state are separate facts on a row**: the default
  engine is the *absent* one on a new Mac, so a disabled "In use" offered
  nothing. **`EngineEligibility` gates ahead of both, and at launch** — a row
  is a view, so a 30B choice restored from `UserDefaults` meets no gate before
  the coordinator uses it. `select(_:)` refuses too, and is the only mover.
- **A path that clears its output ends by setting something** — `download`'s
  callers used `try?` and `runTest` returned silently, leaving a vanished bar
  and a test box reset to its placeholder.
- **Onboarding completion is stored, never inferred from the TCC grant**,
  which cannot say whether anyone chose an engine — so whoever granted it
  first never saw the model step. The step persists too. Continue waits on an
  in-flight download, or the practice hotkey starts a second transfer.
- **`AppPresence` is the ⌘Tab switch, with its own `UserDefaults`.** ⌘Tab,
  the Dock and the menu bar are one activation policy, so the label must name
  the Dock; `start()` is required because `LSUIElement` pins launch to
  `.accessory`.
- **`hotkey` and `fixedKeyEquivalent` are different facts.** A hotkey is
  user-recordable, so copying one into a menu makes a second version that goes
  stale — those get a badge re-read on every open. `⌘,` is fixed, so Settings
  carries a real equivalent; Quit stays bare, `⌘Q` on an app meant to keep
  running being an invitation nobody asked for.
- **A dead-key binding is cautioned; a printable one is merely reported.**
  `⌥I ⌥E ⌥U ⌥N` start accents by swallowing the next keystroke, and a Carbon
  hotkey consumes the event, so binding one removes `î é ü ñ` everywhere with
  nothing to connect it to. `characterCost` is the *other* outcome and not a
  caution: every printable binding costs a glyph — `⌥R` costs `®` — and that
  cost is why `⌥R` beat `⌘I`, so dressing it as a fault reports the reason
  for the choice as a problem, and one firing on the default teaches people
  to skip the two that matter. One `UCKeyTranslate` call answers both.
- **Each `Preset` field carries its own rule** into `PresetField`: a blank
  subtitle is fine, a blank name is not — nothing can label that row.
- **Claims about the user's text are pinned by tests** — `PrivacyCopy`,
  `ReplacementCopy`, `exclusionCaveat`, `passwordPromise`. "Nowhere" was
  false (three `NSPasteboard.general` writes); `TransientType` is convention,
  not enforcement; and "passwords are never read" was one browser measured
  once, standing in for every app forever — the subrole check needs an
  element, the secure-input flag needs the host to set it, and an app
  exposing neither is a case the chain has no way to see. **The test forbids
  the absolutes across both surfaces making the claim**: the pressure is
  always back toward the reassuring version, and fixing one string leaves
  the drift alive in the other.

## Seams

| Seam | Production value | Tested with |
|---|---|---|
| `AppPresence.setPolicy` | `NSApp.setActivationPolicy` | `PolicyRecorder` |

Tests are in `AppCoreTests` — one per SwiftPM target, not per directory.
