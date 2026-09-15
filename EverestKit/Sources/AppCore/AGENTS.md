# AppCore — the app shell's decisions, made testable

Everything the menu-bar app decides lives here: an app target has no test
runner, which is how four subsystems ended up untested and forced a rebuild.
**Any branch there belongs here.** No SwiftUI, no KeyboardShortcuts.

## `RewriteCoordinator`

One transaction at a time, superseded by a counter. Both halves are needed —
engine told to stop **and** its late output discarded — or a buffered
`.finished` writes into a document seconds later.

- **The token is bound at `begin()`, carried in `Transaction`, never
  re-read.** `run` sampled `generation` on entry — after `quickImprove`
  suspends on the settings read — so a second press there let the first adopt
  the new token, and both compared it to itself and wrote. `pending` carries
  its token too, so a snapshot outliving its transaction refuses itself. Until
  this, only the shared engine's one `TransactionBox` stopped the second
  write — by accident, and only while both presses resolved one `EngineID`.
- **Capture before any panel, always** (root §7), read once into `pending`.
- **`.finished` is the engine stopping, not the transaction ending**, so this
  drives the terminal state; `Overlay` only maps it to `.applying`.
- **Every exit is terminal, including the empty stream.** Returning silently
  on no `.finished` stranded the panel on "Rewriting" forever, with the check
  above having already proved the transaction current.
- **`prepare` checks the generation and cancels its task**, or a percentage
  arriving after Escape re-presents a panel whose key monitors are already
  released — unclosable — while the abandoned 2.3 GB fetch runs on.
- **Auto-dismiss reads `PanelState.autoDismissAfter`**, so a later state
  brings its own schedule; `nil` is `heldForManualCopy`, the only copy.
- **Progress drains one `AsyncStream`**: tasks made in order do not run in
  order, and a bar going backwards reads as failure. **Capture refusals are
  `.error`** — `.refused` claims a model declined, before one was consulted.
- **Test box and hotkey share one engine and `TransactionBox`, deliberately**,
  so either cancels the other: a second engine doubles resident memory for
  2.3 GB and a queue holds work one keystroke retries. The silence was the bug.

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
  hole. `⌘I`→`⌃⌥I` moved once and every screen kept saying `⌘I`: a literal is
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
  permission first never saw the model step. The step persists too.
- **`AppPresence` is the ⌘Tab switch, with its own `UserDefaults`.** ⌘Tab, the
  Dock and the menu bar are one activation policy, so the label must name the
  Dock; `start()` is required because `LSUIElement` pins launch to
  `.accessory` and a change-only preference resets overnight.
- **`MenuCommand.hotkey` is `nil` for Settings, Setup Guide and Quit** — `⌘,`
  and `⌘Q` work only while an Everest window is key, and this menu is read
  over other apps. Rendering is the app target's: a key code needs the layout.
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
