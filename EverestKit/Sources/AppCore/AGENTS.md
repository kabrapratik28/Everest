# AppCore — the app shell's decisions, made testable

Everything the menu-bar app decides lives here: an app target has no test
runner, which is how four subsystems ended up with zero tests and forced a
rebuild. **Any branch there belongs here.** No SwiftUI, no KeyboardShortcuts —
view models are plain `ObservableObject`.

## `RewriteCoordinator`

One transaction at a time, superseded by a counter, not a task handle: a second
press interleaves at the first suspension, bumps `generation`, and the older
unwinds at its next check. Both halves are needed, the engine told to stop
**and** its late output discarded; only the first stops a buffered `.finished`
writing into a document seconds later.

**Capture happens before any panel, always** (root §7), read once into
`pending`; `TargetSnapshot` is `@unchecked Sendable` and this actor never fans
one out. **`.finished` is the engine stopping, not the transaction ending**, so
the coordinator drives the terminal state and `Overlay` only maps it to
`.applying`. **Auto-dismiss reads `PanelState.autoDismissAfter`**, never its own
table, so a later state brings its schedule; `nil` is `heldForManualCopy`, the
only copy. **Progress drains from one `AsyncStream`** — tasks made in order do
not run in order, and a bar going backwards reads as failure. **Capture
refusals are `.error`**; `.refused` reads "the model declined", false for
something settled before any model was consulted.

## `EngineFactory` returns the same engine every time

**A factory handing back one instance looks wrong; it is the fix.** A fresh
`MLXTokenProducer`'s `LoadedModel` starts empty, so one engine per transaction
gave that cache a one-rewrite lifetime: never a hit, 2.3 GB re-read per press.
`.ready` short-circuits the download, never the load. **Eviction asks the
disk**, or a delete frees the gigabytes and no memory while `availability()`
says `needsDownload` and the retained producer still generates. An entry is
exempt until its weights are *seen*, or a press mid-download drops the engine
that download spent minutes warming. **`supersede()` nils `active` at the
*next* transaction's start** — held through idle, dropped as it is wanted, and
1x rather than 2x peak memory defends that ordering.

## The Settings screens

**`AppPresence` is the ⌘Tab switch, and it is not in `AppSettings`.** ⌘Tab, the
Dock icon and the menu bar are one thing — the activation policy — so the label
must name the Dock too. Own `UserDefaults`, like `ShortcutNotice`. `start()` is
not optional: `LSUIElement` pins every launch to `.accessory`, so a preference
applied only on change turns itself off overnight.

**`MenuCommand.hotkey` is `nil` for Settings, Setup Guide and Quit** — not
unbound: `⌘,` and `⌘Q` work only while one of Everest's own windows is key, and
this dropdown is only read over another app. Rendering the other two is the app
target's, because key-code-to-character needs the active keyboard layout and a
second formatter could disagree with the recorder that set the binding.

**`Row.isSelected` is on the row**, so the mark and the setting cannot disagree;
`select(_:)` is the only mover, onboarding included. **Each `Preset` field
carries its own rule** into `PresetField`: a blank subtitle is allowed, a blank
name is not — it leaves a picker row nothing can label.

## Seams, and their one production type each

| Protocol | Production type | Tested with |
|---|---|---|
| `Sleeping` | `TaskSleeper` | `RecordingSleeper` |
| `capture` / `apply` | assigned in `AppDelegate` | closures |
| `engineFor` | `EngineFactory.live(for:)` | `StubEngine` |
| `AppPresence.setPolicy` | `NSApp.setActivationPolicy` | `PolicyRecorder` |

`SystemProbing`'s conformer is **`TextBridge.SystemProbe`**: import it, never
add a second, as two public types with one name do not compile. Tests:
`swift build --target AppCoreTests && xcrun xctest .build/out/Products/Debug/AppCoreTests.xctest`
