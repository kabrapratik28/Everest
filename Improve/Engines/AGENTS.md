# Everest — Engines: decisions and rationale

Three files: `ModelDownloader.swift` fetches a model, `MLXEngine.swift` runs it, `AppleFoundationEngine.swift` runs Apple's instead. Both engines implement `RewriteCore.RewriteEngine` and nothing outside this directory knows which one is in use.

Written 2026-09-14 against mlx-swift-lm `main` at commit `3e6ea1ede1596f05c1715d6b82567619276e98f0` (the 3.x line), swift-huggingface 0.10.1, swift-transformers 1.3.4, and the macOS 27.0 SDK with a macOS 26.0 deployment target.

---

## 0. Read this before you try to build: MLX needs the Metal Toolchain

If a build of this directory dies with something like

```
error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain
error: CompileMetalFile .../mlx-swift/Source/Cmlx/mlx-generated/metal/rms_norm.metal failed with a nonzero exit code
```

nothing is wrong with the code. Run this once, on the machine:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**Why it happens.** mlx-swift-lm depends on mlx-swift, whose `Cmlx` target ships roughly forty `.metal` shader sources under `Source/Cmlx/mlx-generated/metal/`. SwiftPM picks those up automatically and compiles them into a `default.metallib` as part of an ordinary build. Xcode 26 split the Metal toolchain payload out of the base Xcode install, so a stock Xcode has `metal` on `PATH` but cannot execute it. `xcrun -f metal` resolves happily and tells you nothing; only invoking it fails.

**Why it is confusing.** The failure happens during shader compilation, which is *before* Swift type-checking of `MLXLMCommon`, `MLXLLM` or anything in this directory. So a Swift mistake and a missing toolchain look identical from the top of the log: a wall of `CompileMetalFile` errors and no Swift diagnostics at all. Check `xcrun metal -c some.metal -o some.air` actually produces a file before you start hunting for a type error.

It affects `swift build`, `xcodebuild`, and ⌘R equally, so a machine that can run this app can also build it. Expect the first build after installing the toolchain to take several minutes on the Metal kernels alone. That is normal, not a hang.

**Type-checking without it, if you must.** Excluding `"mlx-generated/metal"` from `Cmlx`'s `platformExcludes` in a *scratch copy* of mlx-swift's `Package.swift` produces Swift modules that type-check correctly and a binary that cannot run inference. Useful for a quick compile check on a machine you do not control. Never do this to the real dependency graph.

---

## 1. The mlx-swift-lm API, and where it was verified

Do not write MLX code from memory. This API has changed more than once, and the 3.x line on `main` is a different shape from every tutorial and from the 2.x releases. Everything below was read out of a resolved checkout, not recalled. If you need to check it again, resolve the package into a scratch directory and read `.build/checkouts/mlx-swift-lm/Libraries/`.

**The 3.x break.** mlx-swift-lm 3.x removed its own dependency on a downloader and a tokenizer. The package now declares two protocols and expects you to supply implementations. That is why this app depends on `huggingface/swift-huggingface` and `huggingface/swift-transformers` directly: they are not transitive any more.

| What | Where it was read |
|---|---|
| `MLXLMCommon.Downloader` — `download(id:revision:matching:useLatest:progressHandler:) async throws -> URL` | `Libraries/MLXLMCommon/Downloader.swift` |
| `MLXLMCommon.TokenizerLoader` — `load(from directory: URL) async throws -> any Tokenizer` | `Libraries/MLXLMCommon/TokenizerLoader.swift` |
| `MLXLMCommon.Tokenizer` — the ten members the bridge implements | `Libraries/MLXLMCommon/Tokenizer.swift` |
| `ModelConfiguration(id:revision:...)` and `ModelConfiguration(directory:...)`, with `id` a mutable `Identifier` that is either `.id(String, revision:)` or `.directory(URL)` | `Libraries/MLXLMCommon/ModelConfiguration.swift` |
| `GenericModelFactory.loadContainer(from:using:configuration:useLatest:progressHandler:)` and the local-directory overload `loadContainer(from directory:using:)` | `Libraries/MLXLMCommon/ModelFactory.swift` lines 179 and 206 |
| `resolve(configuration:from:useLatest:progressHandler:)` — only calls the downloader on the `.id` branch, never on `.directory` | `Libraries/MLXLMCommon/ModelFactory.swift` line 233 |
| Download globs `["*.safetensors", "*.json", "*.jinja"]` | `Libraries/MLXLMCommon/ModelFactory.swift` lines 7-8, `package` scope |
| `LLMModelFactory.shared`, and `"qwen3"` registered in its type registry | `Libraries/MLXLLM/LLMModelFactory.swift` lines 648 and 67 |
| `ChatSession(_ model: ModelContainer, instructions:speculativeDecoding:generateParameters:...)` | `Libraries/MLXLMCommon/ChatSession.swift` line 361 |
| `ChatSession.streamResponse(to: [Chat.Message]) -> AsyncThrowingStream<String, Error>` | `Libraries/MLXLMCommon/ChatSession.swift` line 811 |
| `GenerateParameters(maxTokens:maxKVSize:...temperature:...)`, temperature is `Float` | `Libraries/MLXLMCommon/Evaluate.swift` lines 79 and 191 |
| `ModelContainer.encode(_:) async -> [Int]`, `ModelContainer.generate(input:parameters:...)` | `Libraries/MLXLMCommon/ModelContainer.swift` |
| Cancellation: the decode loop is `while !Task.isCancelled`, and the stream's `onTermination` cancels the generation task | `Libraries/MLXLMCommon/Evaluate.swift` lines 2373 and 2484 |

**There is no high-level `loadModel(id:)`.** The 3.x entry points are `LLMModelFactory.shared.loadContainer(...)` and the free functions `loadModelContainer(from:using:configuration:progressHandler:)`. The `ChatSession` type in the README is real and is what this code uses, but it wraps a `ModelContainer` you loaded yourself.

**The macros are deliberately not used.** `MLXHuggingFace` ships `#huggingFaceLoadModelContainer`, `#hubDownloader()` and `#huggingFaceTokenizerLoader()`, and the README presents them as the easy path. `TransformersTokenizerLoader` and `TransformersTokenizerBridge` in `MLXEngine.swift` are the hand-written equivalent of what those macros expand to; the expansion source is `Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift` if you ever need to re-derive it. Two reasons for writing it out. A macro-using target makes Xcode refuse to build until the person at the keyboard clicks through a "trust this macro plugin" prompt, which is a bad first five minutes for a fresh checkout. And `#hubDownloader()` hands the factory a `HubClient` pointed at the shared `~/.cache/huggingface`, which would put a 2.3 GB download somewhere this app cannot show, size, or delete.

---

## 2. MLX gives deltas, this app wants snapshots

`ChatSession.streamResponse` yields the text each token decoded to. `RewriteEvent.outputSnapshot(String)` carries the whole output so far, every time. `MLXEngine.run` keeps a running `accumulated` string and emits that.

The accumulation happens here, once, and not in the overlay or the coordinator, because Apple's `streamResponse` is already cumulative. If the engines both emitted deltas, `AppleFoundationEngine` would have to diff Apple's snapshots back into deltas so that something downstream could re-accumulate them, which is two conversions to get back where it started. And a dropped or coalesced UI update costs nothing with snapshots, where with deltas it silently corrupts the result and there is no way to notice.

`AppleFoundationEngine` therefore forwards `snapshot.content` unchanged. Do not "make the two engines consistent" by adding accumulation there: it would concatenate the whole output to itself on every token.

---

## 3. The model, and the one substitution that must never happen

The default is `mlx-community/Qwen3-4B-Instruct-2507-4bit`. Section 4 of the root `AGENTS.md` carries the full comparison; the part that matters when you are in this directory is why a newer Qwen may not be dropped in.

**No Qwen3.5 model may be substituted.** It is a vision-language model: `Image-Text-to-Text` pipeline tag, a vision encoder you download and never use. Thinking mode is on by default and the Qwen3 `/nothink` toggle does not turn it off. The MLX builds load through `mlx_vlm`, not `mlx_lm`, so `LLMModelFactory` is the wrong entry point entirely. Every rewrite would run roughly ten times slower through reasoning tokens the user never sees. This has been reverted to a Qwen3.5 by people reading download counts twice already.

**The trap is live in the dependency, and it compiles.** mlx-swift-lm ships ready-made registry entries for exactly the models that must not be used. If you are here because you were about to reach for one of these names, that is what this section is for:

| Symbol in `Libraries/MLXLLM/LLMModelFactory.swift` | Line | Do not use |
|---|---|---|
| `LLMRegistry.qwen3_5_2b_4bit` → `mlx-community/Qwen3.5-2B-4bit` | 356 | Vision-language, thinking on by default |
| `LLMRegistry.qwen3_6_27b_4bit` → `mlx-community/Qwen3.6-27B-4bit` | 362 | Same family, same problems |
| type-registry keys `"qwen3_5"`, `"qwen3_5_moe"`, `"qwen3_5_text"` | 70-72 | Registered, so a checkpoint loads without complaint |

Because those keys are registered, substituting one **builds cleanly, loads without error, and produces plausible-looking output**. The only visible symptom is that every rewrite got roughly ten times slower, which reads as "the app is slow" rather than "somebody changed the model". That is precisely how this gets reverted a third time. Recency is not an argument.

`Qwen3-4B-Instruct-2507-4bit` is right because the 2507 refresh split Instruct and Thinking into separate models. There is no thinking mode to forget to disable, because the model does not have one. Its `config.json` reports `model_type: "qwen3"`, which `MLXLLM` maps to `createQwen3CompatibleModel`, so the plain text path works.

**The model is downloaded, never bundled.** Shipping 2.3 GB inside a menu-bar app is hostile; shipping the 17.2 GB option is absurd. A download also means the user can delete it from Settings and get the disk back, and can choose not to have it at all by using Apple's engine.

---

## 4. Where the download goes, and why not exactly where the plan says

The plan says `~/Library/Application Support/Everest/Models/<repoID>/`. The files land at:

```
~/Library/Application Support/Everest/Models/
  models--mlx-community--Qwen3-4B-Instruct-2507-4bit/
    blobs/ refs/ snapshots/<commit>/
  .ready/models--mlx-community--Qwen3-4B-Instruct-2507-4bit
```

Same root, Hugging Face cache layout inside it. `HubClient` has two snapshot calls: one returns the cache path, the other takes a `to: destination` and **copies** every file there with `FileManager.copyItem` (`swift-huggingface/Sources/HuggingFace/Hub/HubClient+Files.swift`, `copySnapshotToLocalDirectoryIfNeeded`). The literal layout would mean 4.6 GB on disk for a 2.3 GB model, or 34 GB for the 30B option, with the duplicate living somewhere the delete button does not know about. Rooting the cache at our own directory instead gives one copy, resumable downloads, and a single tree to remove. This deviation from the plan's path string was reviewed and accepted.

Do not point the client at `HubCache.default`. That is `~/.cache/huggingface`, shared with every other tool on the machine, and Settings could neither size it nor safely delete it.

### Deleting a model has to remove four things, not one

`HubCache` scatters a repository across four locations, three of which are **not** inside `models--org--name/`:

| Location | Written by |
|---|---|
| `models--org--name/` — `blobs/` (including any `<etag>.incomplete`), `refs/`, `snapshots/` | `HubCache.repoDirectory` |
| `.metadata/models--org--name/` | `HubCache.metadataDirectory` — a sibling, not a child |
| `.locks/models--org--name/...` | `HubCache.lockPath(for:)` mirrors any cached path under a top-level `.locks` tree |
| `.ready/models--org--name` | ours, see §5 |

`delete(_:)` removes all four. Removing only the first looks correct in testing, because the gigabytes do go away, and leaves lock and metadata trees behind forever. They are small, which is exactly why the leak would sit there for a year before anyone noticed that a user who deleted a model to reclaim space never quite got all of it back.

`residualBytes(for:)` exists to assert this: it measures the same four locations, so a nonzero result after a delete means something was missed rather than merely moved. If you add a fifth location to the cache layout, add it to both functions or the assertion stops being one.

In-progress `hf-download-*.tmp` files are written to the system temp directory rather than here, and are the OS's to clean up.

---

## 5. A model is not "ready" until it has loaded once

`ModelDownloader.isReady(_:)` is false until `markReady(_:)` has been called, and `markReady` is only called by `MLXEngine` after `LLMModelFactory.loadContainer` returns. The marker is a file under `.ready/` containing the commit hash it was proven at, so it survives relaunch and is invalidated by a different revision.

A download can complete and still produce a model that will not load: a truncated safetensors file, or an architecture this build of mlx-swift-lm has no entry for. `looksComplete` catches only the obvious half-download (no `config.json`, no weights at all) and is explicitly not a substitute for loading. Without the marker, a model in that state reports `.ready` forever and fails identically on every hotkey press, and there is no path in the UI that would ever re-download it.

Revisions are pinned to exact commit hashes in `ModelDownloader.pinnedRevisions`, read from the Hugging Face API on 2026-09-14. A moving `main` can swap the weights under an install that was already proven to load. A repository with no entry falls back to `main`; add the hash when you add the repository.

---

## 6. Apple availability is re-checked on every single request

`AppleFoundationEngine.run` calls `SystemLanguageModel.default.availability` at the top of every rewrite, not once at launch and not once per session.

Apple Intelligence is a toggle in System Settings. A user can turn it off between two hotkey presses, and the system can evict and re-download the model on its own schedule. A cached answer from launch is a guess, and the failure mode of guessing wrong is an opaque error at the moment the user is trying to get work done. The check costs a property read.

**`SystemLanguageModel.default` only. Never `PrivateCloudComputeLanguageModel`.** The macOS 27 SDK adds that type right next to the one used here, with a nearly identical `availability` surface, and it would produce better output. It also sends the selected text to Apple's servers, which breaks the only promise this app makes. This is a product constraint, not a performance tradeoff.

The engine is wrapped in `#if canImport(FoundationModels)` with an `#else` stub that reports itself unavailable, so the app builds and runs on a toolchain without the framework and the Settings UI needs no separate path for it. There is no `if #available(macOS 26.0, *)` because the deployment target is already 26.0 and the check would be dead code; the real runtime gate is the per-request availability read, which is what actually varies.

---

## 7. Guardrail refusals get their own message

`AppleEngineError` has eleven cases and each one has a distinct sentence. Resist folding them into "generation failed".

The four that matter most have four completely different fixes: turn on Apple Intelligence, wait for the system to finish downloading, select less text, switch engine. One generic message sends the user looking in the wrong place three times out of four.

A guardrail refusal is its own case for a further reason. Apple's content filter cannot be disabled, and it fires on ordinary text: a paragraph about a death, routine political prose. The user is looking at their own sentence and being told "something went wrong", with no way to tell whether the app is broken, the model is broken, or their writing tripped something. `.guardrailRefusal` says the filter refused it, says nothing left the Mac, and points at the local model that will rewrite it. That turns a dead end into one click.

`.refusal` is kept separate from `.guardrailViolation`: the first is the model declining, the second is the safety layer intercepting. They read the same to a user in a hurry but they are different systems and conflating them in the code makes the next bug harder to place.

Both error families are handled. `LanguageModelSession.GenerationError` is what a macOS 26 machine throws; macOS 27 deprecated it in favour of `LanguageModelError` with renamed cases (`exceededContextWindowSize` became `contextSizeExceeded`, and so on). The deployment target is 26.0 and the SDK is 27.0, so either can arrive at runtime and both are mapped. `mapLegacy` holds the cast and the switch together inside one function annotated `@available(macOS, deprecated: 27.0)`, which is what will keep the build warning-free on the day the target moves to 27.

---

## 8. Cancellation actually stops decoding

`cancel()` cancels the `Task` that owns the stream. That is load-bearing rather than cosmetic: mlx-swift-lm's decode loop is `while !Task.isCancelled` and checks between every token, and `ChatSession` cancels its inner generation task from the stream's `onTermination`. Dropping the result instead would leave the GPU decoding several hundred tokens for a panel that is already gone, which on the 30B option is seconds of a stalled machine.

The task is registered in `TransactionBox` **synchronously**, inside the `AsyncThrowingStream` initializer, before `stream(_:)` returns. An earlier version hopped to an actor to record it, which left a window where a caller doing `stream()` then `cancel()` on the next line would find nothing registered and leave the generation running. `TransactionBox` uses a lock rather than an actor for exactly this reason; the loaded `ModelContainer` still lives in an actor, because loading is async and two hotkey presses half a second apart must not start two loads of the same 2.3 GB model.

`begin` also cancels whatever it replaced, so a second hotkey press cannot leave two streams racing to fill the same panel.

---

## 9. Generation limits

`EngineLimits` in `MLXEngine.swift` holds temperature, the context cap and the output budget. `AppleFoundationEngine` reads the same values. They live in the app target rather than `RewriteCore` because they describe what a decoder is allowed to do, not what a rewrite means, and because keeping one copy is what stops the two engines from quietly diverging.

- **Temperature 0.2.** A rewrite should be the same sentence, better. Sampling variety is a liability here, not a feature.
- **Output budget `min(max(64, inputTokens × 1.4), 768)`.** The floor stops a one-line selection being cut off mid-word. The ceiling stops a model that has started rambling from holding the panel open for a minute.
- **Context cap 8192 (`maxKVSize`).** Not a model limit: Qwen3-4B-Instruct-2507 reports `max_position_embeddings: 262144`. It is a memory cap, and it is far above the 8,000-character input ceiling the selection layer enforces.

`MLXEngine` counts input tokens with the real tokenizer via `ModelContainer.encode`. `AppleFoundationEngine` has no reachable tokenizer and estimates four characters per token, which only has to be close enough to size a budget.

---

## 10. Nothing content-bearing is ever logged

The `Logger` calls here carry counts and error type names, never text. `log.info("rewrite generated, \(count) characters")` is the shape; interpolating the rewrite, the prompt, or the selection is not. Selected text in `OSLog` defeats the entire local-only premise of the app, and `OSLog` persists.

### The subsystem is read from the bundle, never written as a literal

Every file here declares its logger the same way the rest of the app target does:

```swift
private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "engines.mlx"
)
```

A hardcoded subsystem is a silent failure waiting to happen. This directory briefly carried `"com.everest.app"` while `project.yml` was producing `com.kabrapratik.Everest` from `bundleIdPrefix` plus the target name. Nothing warns about that: the app logs happily, `log stream --subsystem com.everest.app` simply returns nothing, forever, with no error to explain why. Reading the identifier at runtime means the two halves of the app cannot drift apart if it ever changes again.

Categories stay literal and stay prefixed `engines.` so `log stream --subsystem <id> --predicate 'category BEGINSWITH "engines"'` picks up all three files.

---

## 11. Things that will bite you

- **`ChatSession` is created fresh per rewrite.** It exists to carry conversation history and a warm KV cache across turns. Reusing one would keep the previous selection resident in memory, which the root `AGENTS.md` §5 rules out. The cost is a prefill per rewrite, which the app pays anyway.
- **`streamResponse(to: prompt)` with a bare `String` is ambiguous** between two overloads that differ only in defaulted parameters. `MLXEngine` calls `streamResponse(to: [Chat.Message.user(prompt)])` instead, which resolves cleanly and also documents that the prompt is a single user turn with no system message.
- **`UnreachableDownloader` is supposed to be unreachable.** It is passed to `loadContainer` so that any future change that turns the configuration back into a `.id` fails loudly instead of silently downloading a second copy somewhere else. If you see its error, a configuration lost its `.directory`.
- **The prompt goes in as one user message with no `instructions:`.** The safety frame is already inside what `PromptBuilder.build` returned and must reach the model exactly as it was written. Do not lift part of it into a system prompt.
