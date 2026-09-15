# AppCore/Settings — what the Settings and onboarding screens decide

Split out of `AppCore/AGENTS.md`, which had grown past its budget with nothing
redundant left to cut. These types share no code and no reasoning with the
transaction engine next door: that one is about one rewrite going through, and
this one is about what the user is told and allowed to change. `Everest/
Settings/` renders these answers and holds none of them.

## Decisions

- **No glyph is ever written down.** `ShortcutCopy` builds shortcut sentences
  from the live binding, `nil` changing their shape rather than leaving a
  hole. The default moved twice — `⌘I`→`⌃⌥I`→`⌥R` — while every screen went
  on saying `⌘I`, so new users pressed a key that did nothing. A literal is
  correct only until someone rebinds.
- **Selection and install state are separate facts on a row**, and conflating
  them broke first run: the default engine is the *absent* one on a new Mac,
  so a disabled "In use" offered nothing. `fitsInMemory` gates ahead of both —
  17.2 GB on a 16 GB Mac must not say "Installed", and after the download is
  too late. `select(_:)` is the only mover, onboarding included.
- **A path that clears its output ends by setting something.** `download`'s
  callers used `try?` and `runTest` returned silently, so a failed fetch left
  a vanished bar and an interrupted test its "appears here" placeholder.
- **Onboarding completion is stored, never inferred from the TCC grant**,
  which cannot say whether anyone chose an engine — so whoever granted the
  permission first never saw the model step. The step persists too, so closing
  the window resumes rather than restarts.
- **`AppPresence` is the ⌘Tab switch, with its own `UserDefaults`.** ⌘Tab, the
  Dock and the menu bar are one activation policy, so the label must name the
  Dock; `start()` is required because `LSUIElement` pins launch to
  `.accessory` and a change-only preference resets overnight.
- **`hotkey` and `fixedKeyEquivalent` are different facts.** A hotkey is
  user-recordable, so copying one into a menu makes a second version that
  goes stale — those get a badge re-read on every open. `⌘,` cannot be
  re-recorded, so Settings carries it as a real key equivalent; Quit stays
  bare, because `⌘Q` on an app meant to keep running is an invitation nobody
  asked for. Rendering a hotkey is the app target's: a key code needs the
  active keyboard layout, which this module cannot ask for.
- **A dead-key binding is cautioned, and the layout decides which.** `⌥I ⌥E
  ⌥U ⌥N` start accents by swallowing the next keystroke, and a Carbon hotkey
  consumes the event — so binding one removes `î é ü ñ` in every app,
  silently, and nobody connects that to a shortcut set weeks ago. Which
  chords are dead is a property of the active layout, so the app target
  measures it with `UCKeyTranslate` and this module only chooses the words.
- **Each `Preset` field carries its own rule** into `PresetField`: a blank
  subtitle is allowed, a blank name is not — nothing can label that row.
- **Claims about the user's text are pinned by tests** — `PrivacyCopy`,
  `ReplacementCopy`, `exclusionCaveat`. "Nowhere" was false (three
  `NSPasteboard.general` writes); `TransientType` is convention, not
  enforcement; and warning when nothing is at stake teaches people to skip it.

## Seams

| Seam | Production value | Tested with |
|---|---|---|
| `AppPresence.setPolicy` | `NSApp.setActivationPolicy` | `PolicyRecorder` |
| `engineFor` | `EngineFactory.live(for:)` | `StubEngine` |

Tests live in `AppCoreTests` with the rest of the module — one test target per
SwiftPM target, so a directory split does not add one.
