# Fix: EVE-005 — concurrent duplicate model loads

**One commit.** Files:

| File | Change |
|---|---|
| `EverestKit/Sources/Engines/LoadOnce.swift` | new — the single-flight actor |
| `EverestKit/Sources/Engines/MLXTokenProducer.swift` | uses it; `LoadedModel` deleted |
| `EverestKit/Tests/EnginesTests/LoadOnceTests.swift` | new — 4 tests |
| `EverestKit/Sources/Engines/AGENTS.md` | records *why* (actor reentrancy) |

No other module touched.

---

## The defect

```swift
// the old LoadedModel
if let container { return container }                    // caller B also sees nil
let loaded = try await LLMModelFactory.shared.load(…)    // …because A is suspended here
container = loaded
```

Swift actors are **reentrant across `await`**. Mutual exclusion covers one turn
on the actor, not a sequence spanning a suspension. Every caller that arrives
while the first load is running sees `nil` and starts its own — two 2.3 GB
models resident at once, or two 17.2 GB on the 30B option.

Its comment said the actor prevented exactly this: *"An actor, unlike
`TransactionBox`, because loading is genuinely async and two hotkey presses
half a second apart must not start two loads of the same 2.3 GB model."* **The
wrong comment is part of the defect** — it is what stopped anyone checking. It
is deleted, not amended.

Reachable from three directions, all live: a second hotkey press during
`prepare` (nothing cancels the first `prepare` task), Settings ▸ Model ▸
Download during a rewrite, and "Rewrite the sample" during a rewrite — the last
two because `EngineFactory` hands the Settings screen and the hotkey path the
same cached engine (my audit finding #3, still open).

## The fix

Publish the **work**, not just the result. The in-flight `Task` is stored
before the first `await`, which is a plain actor-isolated assignment and cannot
be interleaved, so a later caller has something to join.

`defer { inFlight = nil }` matters as much as the join: a failed load left in
the slot would be permanent for the life of the process. Every later caller
would `await` a task that had already thrown, so the only remedy the app offers
— re-downloading from Settings — could never recover, because nothing would
ever attempt a load again.

**Why generic and separate from `MLXTokenProducer`:** `ModelContainer` needs
2.3 GB of weights and a Metal device, so the rule cannot be tested in place.
Extracting it is what `AGENTS.md` already requires — "add an `if` to an adapter
and it belongs on the tested side". `MLXTokenProducer` keeps only translation.

## RED

`LoadOnce` was first written in exactly the old `LoadedModel` shape, so the RED
is the real defect and not a strawman. Eight concurrent callers, not two,
because one pair can interleave innocently and leave a flaky test:

```
✘ Test "callers arriving during a load join it instead of starting another"
  recorded an issue at LoadOnceTests.swift:49:9:
  Expectation failed: loads.withLock { $0 } == 1
↳ one load, however many callers ask at once
↳ loads.withLock { $0 } == 1 → false
↳   loads.withLock { $0 } → 8
✘ Test run with 32 tests in 9 suites failed after 0.213 seconds with 1 issue.
```

**8 of 8 callers started their own load.** Not a narrow race — every one of
them.

The other three tests passed at RED, which is correct: they pin behaviour the
old code already had (a loaded value is reused; a failed load is retried;
`existing` starts nothing) so that a fix for the race cannot quietly drop it.
Retrying the load on every request would also have made the race test pass.

## GREEN

```
✔ Suite "LoadOnce" passed after 0.051 seconds.
✔ Test run with 32 tests in 9 suites passed after 0.192 seconds.
```

After rewiring `MLXTokenProducer` and deleting `LoadedModel`, still
`✔ Test run with 32 tests in 9 suites passed`. That build is also what proves
the rewiring type-checks against the real MLX API.

Whole package, every target:

```
RewriteCoreTests   ✔ 16 tests passed
EnginesTests       ✔ 32 tests passed
AppCoreTests       ✔ 56 tests passed
TextBridgeTests    ✔ 72 tests passed
OverlayTests       ✔ 68 tests passed
```

## What stays manual

That the real `LLMModelFactory.loadContainer` is the thing being single-flighted.
The rule is tested; the wiring of it into `MLXTokenProducer` is two lines of
translation, verified only by compilation, like the rest of that file.
