# AppCore — the app shell's decisions, made testable

Everything the menu-bar app decides lives here, not in the `.app` target.

**Why:** logic in an app target has no test runner, which is how four
subsystems ended up with zero tests and forced a rebuild. The `.app` keeps only
wiring. **Any branch that lands in the app target belongs here instead.**

Imports neither SwiftUI nor KeyboardShortcuts: view models are plain
`ObservableObject`, and the shortcut recorder is app-target wiring.

## `RewriteCoordinator`

One transaction at a time, superseded by a counter rather than a task handle —
`quickImprove()` runs the whole transaction and a second press interleaves at
the first suspension, bumps `generation`, and the older generation unwinds at
its next check. Two things are needed and neither implies the other: the engine
is told to stop, **and** anything it emits on the way out is discarded. Only
the first leaves a buffered `.finished` writing into a document seconds later.

**Capture happens before any panel, always.** A global monitor observes the
picker's digit without consuming it, so the `3` that picks style 3 also types
itself into the app being rewritten. The selection is read once, held in
`pending`, and that reading is what gets rewritten. `TargetSnapshot` is
`@unchecked Sendable`; the actor is its only owner and never fans one out.

**`.finished` is the engine stopping, not the transaction ending.** Validation
and replacement follow and can fail, so the coordinator drives the terminal
state — `Overlay` only ever maps `.finished` to `.applying`.

**Auto-dismiss reads `PanelState.autoDismissAfter`**, never a table of its own,
so a state added later arrives with its own schedule. `nil` means never, which
is `heldForManualCopy` alone: the panel is then the only copy of the rewrite.

**Progress is drained from an `AsyncStream`, not a task per callback.** Tasks
created in order do not run in order, and a percentage that goes backwards
reads as a failing download. Same reason in `ModelSettingsModel.download`.

**Panel states:** capture refusals are `.error` — `.refused` reads "The model
declined", which is a false account of something that happened before any model
was consulted. `.refused` is for output the validator threw out, and for
Apple's guardrail, where it is exactly right.

## Seams, and their one production type each

| Protocol | Production type | Tested with |
|---|---|---|
| `Sleeping` | `TaskSleeper` | `RecordingSleeper` |
| `capture` / `apply` closures | assigned in `AppDelegate` | closures |
| `engineFor` closure | `EngineFactory.live(for:)` | `StubEngine` |

`SystemProbing`'s conformer is **`TextBridge.SystemProbe`**, beside the
protocol it implements. I briefly had a second one here, having hit the same
missing-adapter gap `tdd-bridge` did; two public types with one name in modules
the app imports together is ambiguous at the use site and does not compile.
Import `TextBridge`; do not add one here.

Tests: `swift build --target AppCoreTests && xcrun xctest .build/out/Products/Debug/AppCoreTests.xctest`
