# AppCore — the app shell's decisions, made testable

Everything the menu-bar app decides lives here: an app target has no test
runner, which is how four subsystems ended up untested and forced a rebuild.
**Any branch there belongs here.** No SwiftUI, no KeyboardShortcuts.

## `RewriteCoordinator`

One transaction at a time, superseded by a counter, not a task handle. Both
halves are needed — engine told to stop **and** its late output discarded — or
a buffered `.finished` writes into a document seconds later.

- **Capture before any panel, always** (root §7), read once into `pending`.
- **`.finished` is the engine stopping, not the transaction ending**, so this
  drives the terminal state; `Overlay` only maps it to `.applying`.
- **Every exit is terminal, including the empty stream.** Returning silently
  on no `.finished` stranded the panel on "Rewriting" forever — the check
  above has already proved the transaction current, so nothing else was
  coming. Reached via the test box, but the hang is this actor's regardless.
- **`prepare` checks the generation and cancels its task**, or a percentage
  arriving after Escape re-presents a panel whose key monitors are already
  released — unclosable — while the abandoned 2.3 GB fetch runs on.
- **Auto-dismiss reads `PanelState.autoDismissAfter`**, so a later state
  brings its own schedule; `nil` is `heldForManualCopy`, the only copy.
- **Progress drains one `AsyncStream`**: tasks made in order do not run in
  order, and a bar going backwards reads as failure.
- **Capture refusals are `.error`.** `.refused` reads "the model declined",
  false for something settled before any model was consulted.
- **Known and bounded:** supersession during the `apply` main-actor hop still
  writes. Revalidation stops the *wrong-target* write, so what is left is an
  unwanted-but-correct one that ⌘Z undoes; closing it needs the generation
  check atomic with the write, which is not worth destabilising supersession.

## `EngineFactory` returns the same engine every time

**A factory handing back one instance looks wrong; it is the fix.** A fresh
`MLXTokenProducer`'s `LoadedModel` starts empty, so one engine per transaction
gave that cache a one-rewrite lifetime: never a hit, 2.3 GB re-read per press.
`.ready` short-circuits the download, never the load. **Eviction asks the
disk**, or a delete frees gigabytes and no memory while `availability()` says
`needsDownload` and the retained producer still generates. An entry is exempt
until its weights are *seen*, or a press mid-download drops the engine that
download spent minutes warming. **`supersede()` nils `active` at the *next*
transaction's start** — held through idle, dropped as wanted, 1x not 2x peak.

## The Settings screens

- **No glyph is ever written down.** `ShortcutCopy` builds shortcut sentences
  from the live binding, `nil` changing their shape rather than leaving a
  hole. The defaults moved `⌘I`→`⌃⌥I`, every screen kept saying `⌘I`, and new
  users pressed a dead key: a literal is correct only until someone rebinds.
- **Selection and install state are separate facts on a row**, and conflating
  them broke first run: the default engine is the *absent* one on a new Mac,
  so a disabled "In use" offered nothing. `fitsInMemory` gates ahead of both —
  17.2 GB on a 16 GB Mac must not say "Installed", and checking after the
  download is too late. `select(_:)` is the only mover, onboarding included.
- **`download` does not throw.** Both call sites used `try?`, leaving a
  vanished bar and an unchanged status; the error's only consumer is a label.
- **`runTest` ends by setting something**, like the coordinator: it clears
  both fields up front, so a silent return blanked the box to its placeholder.
- **Onboarding completion is stored, never inferred from the TCC grant**,
  which cannot say whether anyone chose an engine — so whoever granted the
  permission first never saw the model step. The step persists too, so
  closing the window resumes.
- **`AppPresence` is the ⌘Tab switch, with its own `UserDefaults`.** ⌘Tab, the
  Dock icon and the menu bar are one activation policy, so the label must name
  the Dock; `start()` is required because `LSUIElement` pins every launch to
  `.accessory` and a change-only preference resets overnight.
- **`MenuCommand.hotkey` is `nil` for Settings, Setup Guide and Quit** — `⌘,`
  and `⌘Q` work only while an Everest window is key, and this menu is read
  over other apps. Rendering is the app target's: key-code-to-character needs
  the active keyboard layout.
- **Each `Preset` field carries its own rule** into `PresetField`: a blank
  subtitle is allowed, a blank name is not — nothing can label that row.
- **`PrivacyCopy` is pinned by a test**, like `exclusionCaveat`: it claimed
  text goes "Nowhere", which three `NSPasteboard.general` writes make false.

## Seams, and their one production type each

| Protocol | Production type | Tested with |
|---|---|---|
| `Sleeping` | `TaskSleeper` | `RecordingSleeper` |
| `capture` / `apply` | assigned in `AppDelegate` | closures |
| `engineFor` | `EngineFactory.live(for:)` | `StubEngine` |
| `AppPresence.setPolicy` | `NSApp.setActivationPolicy` | `PolicyRecorder` |

`SystemProbing`'s conformer is **`TextBridge.SystemProbe`**: import it, never
add a second — two public types with one name do not compile. Tests:
`swift build --target AppCoreTests && xcrun xctest .build/out/Products/Debug/AppCoreTests.xctest`
