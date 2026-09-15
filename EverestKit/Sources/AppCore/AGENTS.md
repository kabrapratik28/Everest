# AppCore — the app shell's decisions, made testable

Everything the menu-bar app decides lives here: an app target has no test
runner, which is how four subsystems ended up untested and forced a rebuild.
**Any branch there belongs here.** No SwiftUI, no KeyboardShortcuts. The
screens' own decisions are next door in `Settings/`.

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
- **Every exit is terminal, including the empty stream.** The check above has
  already proved the transaction current, so a silent return on no
  `.finished` stranded the panel on "Rewriting" with nothing else coming.
- **`prepare`'s task is held on the actor and cancelled by `supersede()`.**
  Its generation check runs only when a percentage arrives, so a load that
  emits none — or a request stalled before its first byte — never reached
  one, and Escape took the panel away while the fetch ran on.
- **Auto-dismiss reads `PanelState.autoDismissAfter`**, so a later state
  brings its own schedule; `nil` is `heldForManualCopy`, the only copy.
- **Progress drains one `AsyncStream`**: tasks made in order do not run in
  order, and a bar going backwards reads as failure. **Capture refusals are
  `.error`** — `.refused` claims a model declined, before one was consulted.
- **Test box and hotkey share one engine and `TransactionBox`, deliberately**,
  so either cancels the other: a second engine doubles resident memory for
  2.3 GB and a queue holds work one keystroke retries. The silence was the bug.

## `EngineFactory` retains the active engine, and only it

**A factory handing back one instance looks wrong; it is the fix.** A fresh
`MLXTokenProducer`'s `LoadedModel` starts empty, so one engine per transaction
gave that cache a one-rewrite lifetime: never a hit, 2.3 GB re-read per press.
`.ready` short-circuits the download, never the load. **Eviction asks the
disk**, or a delete frees gigabytes and no memory while `availability()` says
`needsDownload` and the retained producer still generates — exempt until the
weights are *seen*, or a press mid-download drops the engine that download was
warming. **Switching evicts too:** a map per id held 4B *and* 30B, defeating
`EngineEligibility`, which asks whether a model fits *in isolation* — a 24 GB
Mac may pick 17.2 GB, true only if 2.3 GB is not also loaded. Two guards right
alone and wrong together. Apple's engine is exempt, holding none of our
weights. **`supersede()` nils `active` at the *next* transaction's start** —
held through idle, dropped as wanted, 1x not 2x peak.

