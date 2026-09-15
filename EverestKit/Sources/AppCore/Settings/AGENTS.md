# AppCore/Settings — what the Settings and onboarding screens decide

These share no code and no reasoning with the transaction engine next door:
that one is about a rewrite going through, this one about what the user is
told and allowed to change. `Everest/Settings/` renders these and holds none.

## Decisions

- **No glyph is ever written down.** `ShortcutCopy` builds shortcut sentences
  from the live binding, `nil` changing their shape rather than leaving a
  hole. The default moved twice — `⌘I`→`⌃⌥I`→`⌥R` — while screens went on
  saying `⌘I`: a literal is correct only until someone rebinds.
- **Selection and install state are separate facts on a row**, and conflating
  them broke first run: the default engine is the *absent* one on a new Mac,
  so a disabled "In use" offered nothing. **`EngineEligibility` gates ahead of
  both, and at launch** — a row is a view, so a 30B choice restored from
  `UserDefaults` meets no gate before the coordinator uses it. `select(_:)`
  refuses too, and is the only mover, onboarding included.
- **A path that clears its output ends by setting something** — `download`'s
  callers used `try?` and `runTest` returned silently, so a failed fetch left
  a vanished bar and an interrupted test its placeholder.
- **Onboarding completion is stored, never inferred from the TCC grant**,
  which cannot say whether anyone chose an engine — so whoever granted it
  first never saw the model step. The step persists too, so closing resumes.
  Continue also waits on an in-flight download, or the practice hotkey starts
  a second transfer of the same weights.
- **`AppPresence` is the ⌘Tab switch, with its own `UserDefaults`.** ⌘Tab,
  the Dock and the menu bar are one activation policy, so the label must name
  the Dock; `start()` is required because `LSUIElement` pins launch to
  `.accessory`.
- **`hotkey` and `fixedKeyEquivalent` are different facts.** A hotkey is
  user-recordable, so copying one into a menu makes a second version that
  goes stale — those get a badge re-read on every open. `⌘,` cannot be
  re-recorded, so Settings carries a real key equivalent; Quit stays bare,
  `⌘Q` on an app meant to keep running being an invitation nobody asked for.
- **A dead-key binding is cautioned; a printable one is merely reported.**
  `⌥I ⌥E ⌥U ⌥N` start accents by swallowing the next keystroke, and a Carbon
  hotkey consumes the event, so binding one removes `î é ü ñ` everywhere
  with nothing to connect it to. `characterCost` is the *other* outcome and
  deliberately not a caution: every printable binding costs a glyph — `⌥R`
  costs `®` — and that cost is why `⌥R` beat `⌘I`, so dressing it as a fault
  would report the reason for the choice as a problem, and one firing on the
  default teaches people to skip the two that matter. One `UCKeyTranslate`
  call in the app target answers both, because they are one layout question
  and a second mechanism would hide a missing test for the first.
- **Each `Preset` field carries its own rule** into `PresetField`: a blank
  subtitle is fine, a blank name is not — nothing can label that row.
- **Claims about the user's text are pinned by tests** — `PrivacyCopy`,
  `ReplacementCopy`, `exclusionCaveat`. "Nowhere" was false (three
  `NSPasteboard.general` writes); `TransientType` is convention, not
  enforcement.

## Seams

| Seam | Production value | Tested with |
|---|---|---|
| `AppPresence.setPolicy` | `NSApp.setActivationPolicy` | `PolicyRecorder` |

Tests are in `AppCoreTests`: one test target per SwiftPM target, so a
directory split does not add one.
