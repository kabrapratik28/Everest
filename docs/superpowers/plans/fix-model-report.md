# Is the model reloaded on every rewrite?

**Yes. Every rewrite performs a full `loadContainer` of the 2.3 GB weights.**

The root cause is `EngineFactory.live(for:)` in `AppCore`, which is outside my
scope. **No code was changed.** Engines' 19 tests were run as a baseline and
pass unchanged.

---

## 1. The evidence

Four links, each one checked in source. The chain has no branch in it, so this
is a proof rather than an inference.

### Link 1 — a new engine is built per transaction

`Sources/AppCore/RewriteCoordinator.swift:125`, inside `run(snapshot:preset:)`,
which is one rewrite:

```swift
let engine = engineFor(await MainActor.run { settings.engineID })
active = engine
```

`engineFor` is `EngineFactory.live(for:)`, wired at `Everest/App/AppDelegate.swift:69`.

### Link 2 — `live(for:)` builds a fresh producer every call

`Sources/AppCore/EngineFactory.swift:36`:

```swift
return MLXEngine(
    spec: spec,
    store: store,
    fetcher: HubModelFetcher(),
    producer: MLXTokenProducer()     // <- new instance, every call
)
```

### Link 3 — a fresh producer means an empty cache

`Sources/Engines/MLXTokenProducer.swift:19`:

```swift
private let loaded = LoadedModel()
```

`LoadedModel` is an actor whose `container` starts `nil`. Its memoisation
(`if let container { return container }`, :96) is correct and does work. Its
lifetime is one `MLXTokenProducer`, which is one transaction, so the cache
never gets a second hit.

### Link 4 — `prepare`'s short-circuit skips the download, not the load

`Sources/Engines/MLXEngine.swift:63-76`. When `isReady` is true it skips
`ModelDownloader`, then still runs:

```swift
try await producer.load(from: installed)
```

That is by design and documented in `Engines/AGENTS.md`: "`.ready` means
*loaded once*, not *downloaded*". The marker was never a claim that the weights
are in memory.

### And nothing downstream catches it

`LLMModelFactory.loadContainer(from:using:)` has **no cache**. From the pinned
3.31.4 checkout, `MLXLMCommon/ModelFactory.swift:203`:

```swift
public func loadContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader)
    async throws -> ContainerType {
    let context = try await _load(configuration: .init(directory: directory),
                                  tokenizerLoader: tokenizerLoader)
    return _wrap(context)
}
```

`_load` (`MLXLLM/LLMModelFactory.swift:543`) unconditionally re-reads
`config.json`, builds the model, and calls `loadWeights`, which walks every
`.safetensors` file in the directory, runs `sanitize`, `quantize`,
`model.update(parameters:verify: [.all])` and `eval(model)`. A grep for
`NSCache|modelCache|cachedContainer` across `mlx-swift-lm/Libraries/` returns
nothing.

So every press of `⌘I` re-reads 2.3 GB from disk and rebuilds the model before
the first token is produced. That is the stall.

---

## 2. Why the 2.4 GB / 0% CPU reading did not show this

The measurement is real, but it is consistent with both hypotheses, so it
cannot separate them.

MLX keeps a buffer pool of freed allocations. From
`mlx-swift/Source/MLX/Memory.swift:251`:

> The cache limit defaults to the memory limit, which may allow very large
> cache sizes on systems with abundant RAM.

and `memoryLimit` "defaults to 1.5 times the maximum recommended working set
size reported by the device". On a 48 GB machine that is tens of GB, so nothing
ever trims the pool.

When the `ModelContainer` is released, the weight buffers go back to MLX's
pool, not to the OS. Resident memory stays near 2.4 GB whether the model is
loaded or not. 0% CPU is simply the app idle between rewrites.

This makes the defect read as free when it is not: the reload cost is paid in
disk reads and setup work on every rewrite, while the number that would
normally expose it never moves. `MLX.Memory.snapshot()` splits
`activeMemory` from `cacheMemory` and would have told them apart.

---

## 3. One detail worth knowing

`supersede()` (`RewriteCoordinator.swift:116`) runs at the start of the next
transaction and sets `active = nil`, which releases the previous engine, its
producer, and its container. `run()` then builds a new engine and loads.

The effect is that the object graph holds the model for exactly the period it
is useless (idle, between rewrites) and drops it at the moment it is about to
be needed. The one upside is that peak memory is 1x and not 2x, since the old
container goes before the new one is built.

Two other call sites in `ModelSettingsModel` also build a fresh engine and load
the full model: `download` (:78) and the sample-text try-it path (:120). Each
loads 2.3 GB and discards it when the function returns. `refresh` (:56) only
calls `availability()`, which reads the `.ready` marker, so it is cheap.

---

## 4. What I did not do, and why

**No pinning feature, no idle-unload timer, no cache in Engines.**

The correct fix is to stop building a new producer per rewrite. That is a
lifetime fix in `EngineFactory.live(for:)`, and this task says to stop and
report rather than edit `AppCore`. Consistent with that, **Engines needs no
change at all**: `MLXEngine.prepare` calling `producer.load` every time is
right (it is a no-op against a warm producer), and `LoadedModel`'s memoisation
is right. Both are correct code being handed a one-shot object.

Adding a process-global container cache inside `MLXTokenProducer` would make
the symptom go away without touching the cause, and would create a second thing
that has to be invalidated when a model is deleted. Rejected.

### On the idle-unload timer

Not needed, and the numbers say so. One resident model is ~2.4 GB on a 48 GB
machine, and MLX's own buffer pool already holds that much whether we ask it to
or not, so an unload timer would not even return the memory unless it also
dropped `MLX.Memory.cacheLimit`. It would add a timer to leak and a way to be
slow at an unpredictable moment, in exchange for nothing measurable.

There is one eviction the code genuinely needs, and it is not time-based:
**deleting a model must drop the retained engine.** Once `live(for:)` memoises,
`ModelSettingsModel.delete` would remove the weights from disk while the
retained producer keeps a working container in memory. The user frees 2.3 GB of
disk and no memory, and the app is in a state where `availability()` says
`needsDownload` while the producer could still generate. That condition is
deterministic and testable, unlike a ten-minute idle window. Whoever takes the
`AppCore` fix should handle it in the same change. Dropping the memoised engine
is sufficient; the container deallocates with it, so no `unload()` method is
needed on the producer.

---

## 5. Test baseline

No production code was changed, so there is no RED/GREEN to report. The suite
was run before and after reading, unchanged, to confirm the tree is green:

```
$ cd /Users/kabara/Desktop/Everest/EverestKit
$ swift build --target EnginesTests
warning: missing creator for mutated node: (...mlx-swift_Cmlx.bundle/Contents/MacOS)
ok (build complete)

$ xcrun xctest .build/out/Products/Debug/EnginesTests.xctest
...
✔ Suite "ModelStore" passed after 0.014 seconds.
✔ Test run with 19 tests in 7 suites passed after 0.125 seconds.
```

---

## 6. The fix

Two files changed: `Sources/AppCore/EngineFactory.swift` and
`Tests/AppCoreTests/EngineFactoryTests.swift`. Nothing else in `AppCore`,
nothing in `Engines`.

`EngineRegistry` holds one engine per `EngineID` behind a `Mutex`, matching
`TransactionBox`'s reason for a lock over an actor. `live(for:)` becomes one
line through it; the old body is `make(for:)`, unchanged.

Eviction is **pull-based, not a call someone has to remember to make.** An
`EngineFactory.invalidate(id)` would have needed wiring into
`ModelSettingsModel.delete`, which is outside the two files I was given, and
until that wiring landed it would have been dead code. Instead the registry
asks whether the weights are on disk, so *anything* that removes them
invalidates the entry: Settings, a manual `rm`, a revision change in the
catalog. It also fires promptly rather than eventually, because
`ModelSettingsModel.delete` ends with `refresh()` and `refresh` asks for every
engine — the eviction happens inside the delete the user just clicked.

The predicate is `installedSnapshot != nil`, not `isReady`. `ModelDownloader`
clears `.ready` at the *start* of a re-download, which under an `isReady`
predicate would read as a deletion and throw away an engine mid-transfer.

One boolean carries the rest: an entry is only worth evicting once its weights
have been *seen* on disk. Without that, `ModelSettingsModel.download` — which
holds its engine locally through a transfer measured in minutes — has its
registry entry replaced by a cold engine the first time anything else asks, and
a hotkey press during a download is enough. The warm engine then dies when
`download` returns and the next rewrite re-reads 2.3 GB, which is the original
bug reached by a different route.

That also means **the download path is fixed for free**: the engine `download`
warms is the one the registry keeps, so the first rewrite after a download is
warm. `runTest` (the sample-text box) shares the same engine for the same
reason. Neither file was touched.

### No idle-unload timer

The memory does not return to the OS when a container is released (§2), so a
timer would free nothing measurable while adding a mechanism to leak. The
eviction that *is* needed is deletion, which is deterministic and tested.

## 7. RED and GREEN

Full output. Every RED was observed before the code that answers it.

**RED A** — behavioural, against the real `live(for:)`:

```
✘ Test "the same id hands back one producer, so the weights are read once"
  recorded an issue at EngineFactoryTests.swift:33:5: Expectation failed:
  try #require(first.producer as? MLXTokenProducer)
        === #require(second.producer as? MLXTokenProducer)
✘ ... failed after 0.001 seconds with 1 issue.
```

**GREEN A** — memoise per id, nothing else:

```
✔ Test "the same id hands back one producer, so the weights are read once" passed
✔ Test run with 38 tests in 1 suite passed after 0.044 seconds.
```

**RED B** — compile, the test shaping the API before the parameter existed:

```
EngineFactoryTests.swift:50:21: error: extra argument 'hasWeights' in call
error: Build failed
```

**GREEN B** — evict when the weights are gone:

```
✔ Test "weights leaving the disk drop the engine that was holding them" passed
✔ Test run with 39 tests in 1 suite passed after 0.044 seconds.
```

**RED C** — behavioural; naive eviction discards the engine a download is warming:

```
✘ Test "the engine a download warms is the one kept, not one built during it"
  recorded an issue at EngineFactoryTests.swift:80:5: Expectation failed:
  try #require(registry.engine(for: .qwen4B) as? StubEngine) === downloading
✘ ... recorded an issue at EngineFactoryTests.swift:84:5: (same)
✘ ... failed after 0.001 seconds with 2 issues.
```

**GREEN C** — verified on a copy, see §8:

```
✔ every catalog id builds the engine that claims that id
✔ the same id hands back one producer, so the weights are read once
✔ weights leaving the disk drop the engine that was holding them
✔ the engine a download warms is the one kept, not one built during it
✔ models live in a directory this app owns, not the shared Hugging Face cache
✔ Test run with 5 tests in 0 suites passed after 0.002 seconds.
```

### Mutation, on a copy, never the shared tree

RED B was only a compile error, so it was re-proved by deleting the eviction
(`weightsWereDeleted = false`). It failed alone, which also shows the three
tests are not redundant under §1:

```
✔ the same id hands back one producer ...
✘ Test "weights leaving the disk drop the engine that was holding them"
  recorded an issue at EngineFactoryTests.swift:56:5
✔ the engine a download warms is the one kept ...
✘ Test run with 5 tests in 0 suites failed with 1 issue.
```

That mutation then exposed a real gap. Deleting the line that promotes
`sawWeights` when the weights land broke **nothing**:

```
✔ Test run with 5 tests in 0 suites passed after 0.002 seconds.
```

Unprotected, that line is the difference between "delete frees the memory" and
"delete frees the memory only if you restart the app first" — for any model
downloaded in the current session, which is the ordinary case. So a sixth test
was added.

**Disclosure, per §0:** this one had no honest failing ordering available. It
pins a third state in a sequence whose halves the other two tests already
cover, so the code was already correct when it was written. It was proved by
mutation instead, and it fails alone:

```
✘ Test "a model downloaded and then deleted in one session lets its engine go"
  recorded an issue at EngineFactoryTests.swift:114:5: Expectation failed:
  try #require(registry.engine(for: .qwen4B) as? StubEngine) !== downloaded
✘ Test run with 6 tests in 0 suites failed with 1 issue.
```

Restored, on source verified byte-identical to the shared tree:

```
✔ every catalog id builds the engine that claims that id
✔ the same id hands back one producer, so the weights are read once
✔ weights leaving the disk drop the engine that was holding them
✔ the engine a download warms is the one kept, not one built during it
✔ a model downloaded and then deleted in one session lets its engine go
✔ models live in a directory this app owns, not the shared Hugging Face cache
✔ Test run with 6 tests in 0 suites passed after 0.002 seconds.
```

## 8. Why GREEN C onward was run on a copy

Partway through, the shared `AppCoreTests` target stopped compiling for reasons
outside these two files:

- `overlay` added `keyInterceptor:` to `Overlay.FloatingPanelController.init`
  and updated `OverlayTests` but not `Tests/AppCoreTests/Harness.swift:83`.
- `fix-settings` is mid-RED on `MenuCommandTests.swift`, `AppPresenceTests.swift`
  and `SettingsModelTests.swift`, whose production types do not exist yet.

Both are outside my scope, so neither was touched in the shared tree. Instead
the repo was copied to `/tmp`, `Harness.swift` was given its missing argument
*there*, the other agents' in-flight test files were removed *there*, and both
of my files were `diff`ed against the shared tree to confirm they were
byte-identical before every run. The copy has since been deleted.

This is also a live illustration of the note that landed in root `AGENTS.md`
§8 while I was working: `xcrun xctest` runs a stale bundle when the build
fails. One reading in this session was bogus for exactly that reason and was
discarded, not reported.

**Since resolved.** The lead fixed `Harness.swift` and `fix-settings` landed
`MenuCommand`, so the shared target builds again and the whole suite was re-run
there, not in isolation. 45 tests, all six of mine passing:

```
✔ every catalog id builds the engine that claims that id
✔ the same id hands back one producer, so the weights are read once
✔ weights leaving the disk drop the engine that was holding them
✔ the engine a download warms is the one kept, not one built during it
✔ a model downloaded and then deleted in one session lets its engine go
✔ models live in a directory this app owns, not the shared Hugging Face cache
```

One unrelated failure in that run, not mine and not in my files:
`"every capture refusal explains its own remedy"`
(`RewriteCoordinatorTests.swift:505`, asserting on `com.1password.1password`),
which belongs to the live work on `CaptureFailure`.

**Other suites, accurately:** `EnginesTests` is at 21 tests with one failing,
`"a rewrite the budget cut short is refused, not offered as finished"`
(`MLXEngineTests.swift:174`). It was 19 green when I started; the two new tests
belong to whoever is working in `Engines`, mid-RED. No file in `Engines` was
touched. The rest of `AppCoreTests` was green at 38 and 39 tests before the
break above, and its other files inject their own `engineFor` closures rather
than calling `EngineFactory`, so the registry cannot reach them.

## 9. `AppCore/AGENTS.md`

Done, at exactly 60 of its 60 lines, with an `EngineFactory` section carrying
the *why* for both bugs and the `supersede()` observation.

It was at 58, so it needed 12 lines of cuts to fit 14 of new text. Cut, in
order of how little each was earning:

- The `SystemProbing` paragraph, five lines of first-person war story whose
  operative content is one sentence. Now two lines beside the seam table.
- **Capture happens before any panel** and **`.finished` is the engine
  stopping**, both of which restated root `AGENTS.md` §7 at length. Trimmed to
  the AppCore-specific part with a pointer to root, per §2's rule against
  saying a thing twice.
- Four paragraphs tightened by a line each (the coordinator's opener,
  auto-dismiss, progress, panel states). Rationale kept, words removed.

Nothing's reasoning was dropped, and the two decisions most likely to be
"simplified" away are now the most explicit things in the file.

## 10. Two commits, not one

They are two bugs with different causes, and the second is the subtler.

**Commit 1 — the model is reloaded on every rewrite.** `EngineRegistry`'s
memoisation, `live(for:)` routed through it, `make(for:)` extracted unchanged.
Tests: `liveKeepsOneProducerPerID`. RED A was behavioural, against the real
factory.

**Commit 2 — deleting a model frees the disk but not the memory.** The
`hasWeights` predicate, `weightsInstalled`, `downloadable`, the eviction, and
the `sawWeights` exemption. Tests: `deletedWeightsDropTheCachedEngine`,
`theEngineWarmedByADownloadIsKept`, `weightsArrivingThenLeavingDropTheEngine`.
RED B shaped the API, RED C was behavioural, and the third was proved by
mutation with that disclosed above.

The `AGENTS.md` edit covers both and splits badly; it belongs with commit 2,
which is where the reasoning it records is finished. No git command was run by
me.
