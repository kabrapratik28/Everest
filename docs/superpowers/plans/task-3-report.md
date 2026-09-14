# Task 3 report: engines and model download

Written 2026-09-14.

## Status

Complete. All three source files plus both documentation files are written, and all three compile clean (zero errors, zero warnings) under Swift 6 strict concurrency, `-target arm64-apple-macos26.0`, against the **real** `RewriteCore` package produced by Task 1, the real `mlx-swift-lm`, `swift-huggingface`, `swift-transformers` packages, and the real `FoundationModels` framework. The final verification was a from-scratch build with Metal shader compilation enabled, so this is a genuine end-to-end compile and not a type-check against a stubbed dependency graph.

One environment blocker was found mid-task that affected the whole project and not only this task: the Mac had no Metal Toolchain installed, so any build touching mlx-swift failed before reaching Swift. The team lead installed it (`xcodebuild -downloadComponent MetalToolchain`) and the full build then succeeded. The diagnosis and the fix are recorded as §0 of `Engines/AGENTS.md` so the next agent does not lose an hour to it.

The app was renamed from "Improve" to **Everest** during this task. Model storage is now `~/Library/Application Support/Everest/Models/`, the `OSLog` subsystem is `com.everest.app`, and `Engines/AGENTS.md` uses the new name. No directories were moved or renamed; the lead handles that centrally.

## Files created

```
/Users/kabara/Desktop/Improve/Improve/Engines/ModelDownloader.swift
/Users/kabara/Desktop/Improve/Improve/Engines/MLXEngine.swift
/Users/kabara/Desktop/Improve/Improve/Engines/AppleFoundationEngine.swift
/Users/kabara/Desktop/Improve/Improve/Engines/AGENTS.md
/Users/kabara/Desktop/Improve/Improve/Engines/CLAUDE.md
```

Nothing outside the engines directory was touched. Paths are pre-rename, as instructed.

---

## The verified mlx-swift-lm API

Nothing below was written from memory or from a search result. A scratch SwiftPM package was created at `/tmp/mlxprobe`, `https://github.com/ml-explore/mlx-swift-lm` was resolved into it, and the resolved source was read.

**Resolved versions**

| Package | Resolution |
|---|---|
| `ml-explore/mlx-swift-lm` | branch `main`, commit `3e6ea1ede1596f05c1715d6b82567619276e98f0` (the 3.x line; latest tag is `3.31.4`) |
| `ml-explore/mlx-swift` | 0.31.6 |
| `huggingface/swift-huggingface` | 0.10.1 |
| `huggingface/swift-transformers` | 1.3.4 |
| macOS SDK | 27.0, Swift 6.4, default target `arm64-apple-macosx26.0` |

### The 3.x break matters

mlx-swift-lm 3.x **removed its own downloader and tokenizer dependencies**. The README states this at the top: "The `main` branch is a _new_ major version number: 3.x. In order to decouple from tokenizer and downloader packages some breaking changes were introduced."

Consequence for `project.yml` (Task 5): the app needs **three** packages for inference, not one.

```
https://github.com/ml-explore/mlx-swift-lm    → products MLXLLM, MLXLMCommon
https://github.com/huggingface/swift-huggingface  from 0.9.0  → product HuggingFace
https://github.com/huggingface/swift-transformers from 1.3.0  → product Tokenizers
```

`MLXHuggingFace` is deliberately **not** linked. See "The macros" below.

### Module names

`MLXLLM` and `MLXLMCommon` from mlx-swift-lm; `HuggingFace` from swift-huggingface; `Tokenizers` from swift-transformers. There is no `MLXLMTokenizers` and no `MLXLMHuggingFace` in this version. (mlx-swift-lm's own bundled skill file, `skills/mlx-swift-lm/SKILL.md`, references `MLXLMHuggingFace` from a package called `swift-huggingface-mlx` and `MLXLMTokenizers` from `swift-tokenizers-mlx`. Neither exists. **That skill file is stale relative to the code in the same checkout** — do not follow it.)

### There is no high-level `loadModel(id:)`

The entry points are `LLMModelFactory.shared.loadContainer(...)` and the free functions `loadModelContainer(...)`. `ChatSession` is real and is what this code uses, but it wraps a `ModelContainer` you loaded yourself.

Signatures, with checkout paths (all relative to `.build/checkouts/mlx-swift-lm/`):

| Symbol | Path and line |
|---|---|
| `protocol Downloader { func download(id:revision:matching:useLatest:progressHandler:) async throws -> URL }` | `Libraries/MLXLMCommon/Downloader.swift:28` |
| `protocol TokenizerLoader { func load(from directory: URL) async throws -> any Tokenizer }` | `Libraries/MLXLMCommon/TokenizerLoader.swift:4` |
| `protocol Tokenizer` (10 members: `encode(text:addSpecialTokens:)`, `decode(tokenIds:skipSpecialTokens:)`, `convertTokenToId`, `convertIdToToken`, `bosToken`, `eosToken`, `unknownToken`, `applyChatTemplate(messages:tools:additionalContext:)`) | `Libraries/MLXLMCommon/Tokenizer.swift:6` |
| `ModelConfiguration(id:revision:...)`, `ModelConfiguration(directory:...)`, and `var id: Identifier` where `Identifier` is `.id(String, revision: String)` or `.directory(URL)` | `Libraries/MLXLMCommon/ModelConfiguration.swift:34, 131, 155` |
| `GenericModelFactory.loadContainer(from downloader:using:configuration:useLatest:progressHandler:) async throws -> ContainerType` | `Libraries/MLXLMCommon/ModelFactory.swift:179` |
| `GenericModelFactory.loadContainer(from directory: URL, using tokenizerLoader:) async throws -> ContainerType` | `Libraries/MLXLMCommon/ModelFactory.swift:206` |
| `resolve(configuration:from:useLatest:progressHandler:)` — calls the downloader only on the `.id` branch | `Libraries/MLXLMCommon/ModelFactory.swift:233` |
| `package let modelDownloadPatterns = ["*.safetensors"] + ["*.json", "*.jinja"]` | `Libraries/MLXLMCommon/ModelFactory.swift:7-8` |
| `LLMModelFactory.shared` | `Libraries/MLXLLM/LLMModelFactory.swift:648` |
| `"qwen3": createQwen3CompatibleModel` in the type registry | `Libraries/MLXLLM/LLMModelFactory.swift:67` |
| `ChatSession.init(_ model: ModelContainer, instructions:speculativeDecoding:generateParameters:components:processing:additionalContext:tools:toolDispatch:)` | `Libraries/MLXLMCommon/ChatSession.swift:361` |
| `ChatSession.streamResponse(to: [Chat.Message]) -> AsyncThrowingStream<String, Error>` | `Libraries/MLXLMCommon/ChatSession.swift:811` |
| `Chat.Message.user(_:images:videos:audios:)` | `Libraries/MLXLMCommon/Chat.swift:86` |
| `GenerateParameters(maxTokens:maxKVSize:kvCache:kvBits:kvGroupSize:quantizedKVStart:kvScheme:temperature:topP:topK:minP:...)` — `temperature` is `Float`, default 0.6 | `Libraries/MLXLMCommon/Evaluate.swift:79, 191` |
| `ModelContainer.encode(_ text: String) async -> [Int]`, `ModelContainer.generate(input:parameters:wiredMemoryTicket:tools:) async throws -> AsyncStream<Generation>` | `Libraries/MLXLMCommon/ModelContainer.swift` |
| `enum Generation { case chunk(String), info, toolCall, rejectedToolCall }` | `Libraries/MLXLMCommon/Evaluate.swift:2658` |

### Streaming shape: deltas, confirmed

`ChatSession.streamResponse` yields `String` **chunks**, i.e. deltas, one per decoded token (`ChatSession.swift:811`, mapping `{ $0.chunk }` over `Generation`). The lower-level `ModelContainer.generate` likewise yields `Generation.chunk(String)` deltas. `MLXEngine` accumulates them into a running string and emits `RewriteEvent.outputSnapshot(accumulated)`.

### Download progress

Reported as a Foundation `Progress`, not a `Double`. Two hops:

- `MLXLMCommon.Downloader.download(..., progressHandler: @Sendable @escaping (Progress) -> Void)`
- `HubClient.downloadSnapshot(..., progressHandler: (@MainActor @Sendable (Progress) -> Void)?)` — note it is delivered **on the main actor**, and it is emitted from a 100 ms polling loop (`swift-huggingface/Sources/HuggingFace/Hub/HubClient+Files.swift`, `makeSnapshotProgressSamplingTask`).

`ModelDownloader` converts `progress.fractionCompleted` to the `Double` 0...1 the plan asks for, and clamps it non-decreasing.

### Temperature and max output tokens

`GenerateParameters(maxTokens:maxKVSize:temperature:)`. Temperature is a `Float`. `maxKVSize` is the context cap (`RotatingKVCache`), set to 8192.

### Cancellation genuinely stops decoding

Verified in source, not assumed:

- `Libraries/MLXLMCommon/Evaluate.swift:2373` — the decode loop is `tokenLoop: while !Task.isCancelled`, with an explicit upstream comment about checking **before** `iterator.next()` so no extra `asyncEval` is submitted post-cancellation.
- `Libraries/MLXLMCommon/Evaluate.swift:2484` — `continuation.onTermination` cancels the generation task when the consumer cancels the stream.
- `Libraries/MLXLMCommon/ChatSession.swift:1411` and `:1488` — `ChatSession` cancels its inner generation task both from its own `Task.isCancelled` check and from the stream's `onTermination`.

So `MLXEngine.cancel()` cancelling the consuming `Task` does stop the GPU, it does not merely discard the result.

### The macros

`MLXHuggingFace` provides `#huggingFaceLoadModelContainer(configuration:)`, `#hubDownloader()`, `#huggingFaceTokenizerLoader()`, `#adaptHuggingFaceTokenizer(_:)` and `#huggingFaceLanguageModel(configuration:)`. They are **not used here**. `TransformersTokenizerLoader` / `TransformersTokenizerBridge` in `MLXEngine.swift` are the hand-written equivalent, transcribed from the macro implementation at `Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`.

Two reasons:

1. A macro-using target makes Xcode refuse to build until the person at the keyboard clicks through a "trust this macro plugin" prompt. Bad first five minutes for a fresh checkout, and it would need repeating on every machine.
2. `#hubDownloader()` constructs a `HubClient` pointed at `HubCache.default`, which is the shared `~/.cache/huggingface`. A 2.3 GB download would land somewhere the app cannot show, size, or delete, and the plan requires it under Application Support.

### Note: `/Users/kabara/Desktop/Resonance/` does not exist

The task brief said an existing MLX app lives there. It is not on this machine (`ls: No such file or directory`, and `~/Desktop` contains only `Improve/`, `July:August Expense Analysis/` and some images). Nothing was read from it and nothing was modified. The API above came entirely from the resolved checkout.

---

## The verified FoundationModels API

Read from the SDK's own interface file, not from documentation:

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`

| Symbol | Line | Availability |
|---|---|---|
| `SystemLanguageModel.default` | 385 | macOS 26.0 |
| `SystemLanguageModel.availability -> Availability` | 267 | macOS 26.0 |
| `enum Availability { case available, unavailable(UnavailableReason) }` | 352 | macOS 26.0 |
| `enum UnavailableReason { case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady }` | 365 | macOS 26.0, **not frozen** |
| `LanguageModelSession.init(model: SystemLanguageModel = .default, tools:instructions:)` | 38-41 | macOS 26.0 |
| `streamResponse(to: String, options: GenerationOptions) -> ResponseStream<String>` | 2054 | macOS 26.0 |
| `ResponseStream.Snapshot { var content: Content.PartiallyGenerated; var rawContent }` | 2191 | macOS 26.0 |
| `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`, temperature is `Double?` | 3217 | macOS 26.0 (back-deployed) |
| `LanguageModelSession.GenerationError` | 3534 | macOS 26.0, **deprecated 27.0** |
| `LanguageModelError` | 1528 | macOS 27.0 |
| `LanguageModelSession.Error { case concurrentRequests, transcriptMutationWhileResponding }` | 2026 | macOS 27.0 |
| `PrivateCloudComputeLanguageModel` | 195 | macOS 27.0 — **exists, deliberately unused** |

Three findings worth flagging:

**1. `GenerationError` is deprecated in macOS 27.0 and replaced by `LanguageModelError`, with renamed cases.** `exceededContextWindowSize` → `contextSizeExceeded`, `unsupportedGuide` → `unsupportedGenerationGuide`, `concurrentRequests` moved to `LanguageModelSession.Error`, `assetsUnavailable` moved to `SystemLanguageModel.Error`. Deployment target is 26.0 and the SDK is 27.0, so **either family can arrive at runtime**. Both are mapped. The legacy cast and switch are wrapped in one function annotated `@available(macOS, deprecated: 27.0)`, which keeps the build warning-free when the target eventually moves to 27.

**2. `String.PartiallyGenerated == String`** (via the default `typealias PartiallyGenerated = Self` on `Generable` at line 1183, with `String: Generable` at 1226). So `ResponseStream<String>.Snapshot.content` is a plain cumulative `String` and is forwarded as-is.

**3. `PrivateCloudComputeLanguageModel` is right next to `SystemLanguageModel`** in the 27.0 SDK with a near-identical `availability` surface. It is an easy accidental substitution that would silently break the local-only promise. Called out explicitly in `Engines/AGENTS.md` §6.

The exact case names the brief asked to confirm: `.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.deviceNotEligible)`, `.unavailable(.modelNotReady)`, and `LanguageModelSession.GenerationError.guardrailViolation` — all four exist and are spelled exactly that way. Context overflow is `GenerationError.exceededContextWindowSize` on 26 and `LanguageModelError.contextSizeExceeded` on 27.

---

## Model verification

Queried the Hugging Face API directly:

| Repo | Commit pinned | Pipeline tag | Weight files |
|---|---|---|---|
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` | `text-generation` | 1 × `model.safetensors` |
| `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | `e9675aa3ca5f900ccef55267914466d55ab325fa` | `text-generation` | 4 × `model-0000N-of-00004.safetensors` |

`config.json` of the 4B reports `model_type: "qwen3"`, `eos_token_id: 151645` (`<|im_end|>`), `max_position_embeddings: 262144`. `"qwen3"` is registered in `MLXLLM`'s type registry, so the plain `LLMModelFactory` path is correct — exactly as AGENTS.md §4 claims. The repo IDs match `ModelCatalog.all` verbatim.

Both hashes are hardcoded in `ModelDownloader.pinnedRevisions`, satisfying AGENTS.md §4's "pin an exact revision rather than a moving branch". A repo with no entry falls back to `main`.

**The Qwen3.5 trap is live in the dependency.** `LLMRegistry` in mlx-swift-lm ships `qwen3_5_2b_4bit` and `qwen3_6_27b_4bit` entries and registers `qwen3_5`, `qwen3_5_moe` and `qwen3_5_text` in the model type registry (`Libraries/MLXLLM/LLMModelFactory.swift:70-72, 356-366`). A substitution would compile and appear to work. `Engines/AGENTS.md` §3 records why it must not happen.

---

## What compiled

A scratch package at `/tmp/enginecheck` linking the three engine files against the real dependencies.

| File | Result |
|---|---|
| `ModelDownloader.swift` | Compiles clean |
| `MLXEngine.swift` | Compiles clean |
| `AppleFoundationEngine.swift` | Compiles clean |

Conditions: Swift 6 language mode, strict concurrency, `-target arm64-apple-macos26.0`, macOS 27.0 SDK. **Zero errors and zero warnings.**

Built against the **real `RewriteCore` package** at `/Users/kabara/Desktop/Improve/RewriteCore` (Task 1 had landed by then), not against a stub. The earlier runs used a stub transcribed verbatim from the plan's "Shared interfaces" section; swapping in the real package required no change to any engine file.

The final run was a **from-scratch build with Metal shader compilation enabled**: `.build/out` deleted, the scratch mlx-swift checkout restored to pristine with `git checkout -- Package.swift`, then a full `swift build`. Evidence it was real rather than skipped:

- A genuine 3.7 MB `default.metallib` was produced at `.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, so the ~40 Metal kernels actually compiled.
- `Cmlx.o` (43 MB), `MLXLMCommon.o` (9.0 MB), `MLXLLM.o` (12.7 MB), `Tokenizers.o`, `RewriteCore.o` and `Engines.o` (440 KB) all present.
- `strings Engines.o` contains `Everest/Models`, confirming the post-rename source is what compiled.
- Forcing a recompile with `touch Sources/Engines/*.swift` and rebuilding produced exit 0 and no Swift diagnostics. The only line in the log is a benign SwiftPM bundle-node warning originating in mlx-swift's `Cmlx` resource bundle, not in our code.
- Earlier, the harness was sanity-checked by injecting a deliberate type error into `MLXEngine.swift`; the compiler reported it at the right line. So "it compiled" is not an artifact of the target being skipped.

### The Metal Toolchain blocker, and how it was resolved

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
use: xcodebuild -downloadComponent MetalToolchain
error: CompileMetalFile .../mlx-swift/Source/Cmlx/mlx-generated/metal/rms_norm.metal failed with a nonzero exit code
```

mlx-swift's `Cmlx` target compiles roughly forty `.metal` kernels as part of an ordinary build. Xcode 26 split the Metal toolchain payload out of the base install, so `xcrun -f metal` resolves to a binary but invoking it fails. Without the component, `swift build` and `xcodebuild` both die during shader compilation, before Swift type-checking of `MLXLMCommon`, `MLXLLM` or our code ever begins — which is why the failure looks like a wall of `CompileMetalFile` errors with no Swift diagnostics at all, and is easy to mistake for a code problem.

The team lead ran `xcodebuild -downloadComponent MetalToolchain` and confirmed `xcrun metal -c t.metal -o t.air` then produced a real `.air` file. The full build above followed. This is now §0 of `Engines/AGENTS.md`, with the exact error string so it is greppable.

As an interim measure, before the toolchain landed, the scratch checkout's `mlx-swift/Package.swift` was patched to exclude `mlx-generated/metal`. That patch was reverted with `git checkout -- Package.swift` before the final build and never touched the repo.

**What only surfaced once the kernels compiled for real.** Almost nothing, which is the useful result. The unpatched build emits exactly four warnings, all of them upstream and all from one file:

```
.../Cmlx/mlx-generated/metal/steel/attn/kernels/../../../steel/utils/integral_constant.h:108:6:
  warning: constexpr if is a C++17 extension [-Wc++17-extensions]
.../steel/attn/kernels/steel_attention.h:356:16, :426:14, :436:14  (same warning)
```

These come from mlx-swift's vendored `steel_attention` shader headers using `if constexpr` in Metal Shading Language, which is C++14-based. They are harmless, they are not ours to fix, and they will appear on every clean build — worth knowing so nobody spends time on them. The shaders themselves compile and link into a real `default.metallib`.

The only other build warning is `missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)`, a SwiftPM bookkeeping complaint about mlx-swift's resource bundle. Also upstream, also harmless, also present on every build.

No Metal-specific problem touched our code: zero Swift diagnostics in all three engine files before and after enabling the kernels.

### Not verified

Everything below needs a real 2.3 GB download and a running app, and none of it can be checked by compiling:

- That the download actually completes and lands where `snapshotURL(for:)` expects.
- That `LLMModelFactory` loads this specific checkpoint and produces sensible text.
- That the pinned commit hash works as a `revision` through `HubClient.downloadSnapshot` (the HF API accepts commit SHAs, and `HubClient` has an `isCommitHash` fast path for exactly this, but it has not been exercised).
- Real streaming, real cancellation latency, real memory behavior.
- Anything about Apple Intelligence at runtime, including whether the guardrail actually fires on the kind of text AGENTS.md §4 describes.

---

## Deviations from the brief, and why

**1. On-disk layout** (reviewed and accepted by the lead). The plan says `~/Library/Application Support/Everest/Models/<repoID>/`. The implementation uses that directory as the Hugging Face cache root, so files land at `Models/models--mlx-community--Qwen3-4B-Instruct-2507-4bit/snapshots/<commit>/`.

`HubClient` offers a `to: destination` overload that would produce the literal layout, but it downloads into the cache first and then **copies** every file to the destination with `FileManager.copyItem` (`HubClient+Files.swift`, `copySnapshotToLocalDirectoryIfNeeded`). That is 4.6 GB on disk for a 2.3 GB model and 34 GB for the 30B option, with the duplicate sitting somewhere the delete button does not know about. Same root directory, one copy, resumable, one directory to delete. Recorded in `Engines/AGENTS.md` §4.

**2. `EngineLimits` lives in `MLXEngine.swift`, shared by both engines.** The brief specified exactly three source files in this directory, so the shared constants could not get their own file. `AppleFoundationEngine.swift` reads them. Called out in `Engines/AGENTS.md` §9.

**3. No `if #available(macOS 26.0, *)` around the Apple engine.** The brief asked for `#if canImport(FoundationModels)` plus a runtime availability check. `#if canImport` is there with an `#else` stub that reports itself unavailable, so the app builds and runs without the framework. The `#available(macOS 26.0, *)` check is omitted because the deployment target is already 26.0, making it dead code the compiler warns about. The real runtime gate — the thing that actually varies between one hotkey press and the next — is the per-request `SystemLanguageModel.default.availability` read, which is implemented. Recorded in `Engines/AGENTS.md` §6.

**4. `cancel()` stops decoding but does not abandon an in-flight download.** The brief says `cancel()` must actually stop decoding, which it does. Escaping during the initial 2.3 GB download dismisses the panel and leaves the download running, so the next press is fast and a Settings download is not killed by an unrelated hotkey press. `ModelDownloader.cancelDownload(repoID:)` is the separate, explicit path for stopping a download, for the Settings UI to call. Recorded in `Engines/AGENTS.md` §8.

**5. The output budget counts the selection, not the whole prompt.** `min(max(64, inputTokens × 1.4), 768)` where `inputTokens` is `container.encode(request.text).count`. Counting the assembled prompt would fold the fixed safety-frame overhead into a number meant to track how long the rewrite should be.

---

## Concerns for other tasks

**For Task 5 (`project.yml`):**

- Three packages are needed, not one: `mlx-swift-lm` (products `MLXLLM`, `MLXLMCommon`), `swift-huggingface` from `0.9.0` (product `HuggingFace`), `swift-transformers` from `1.3.0` (product `Tokenizers`). Do not add `MLXHuggingFace`.
- Pin `mlx-swift-lm` to `.upToNextMajor(from: "3.31.3")` rather than `branch: "main"`. Everything here was verified against `main` at `3e6ea1e`, which is within that range. A 2.x pin would break every call in `MLXEngine.swift`, because 2.x has a different API.
- The Metal Toolchain must be installed on any machine that builds this. It is installed on this one now.
- Expect a long first build. mlx-swift compiles a large C++ tree plus forty Metal kernels; the clean build measured here took roughly five minutes.
- The `OSLog` subsystem in all three files is `com.kabrapratik.Everest`, matching the `bundleIdPrefix: com.kabrapratik` plus target name `Everest` that `project.yml` now declares. If the bundle identifier changes, change these too or `log stream --subsystem` stops finding anything.
- **`project.yml` currently pins `mlx-swift-lm` to `branch: main`.** Consider `.upToNextMajor(from: "3.31.3")` instead. Everything in `MLXEngine.swift` was verified against `main` at `3e6ea1e`, which sits inside that range, and this package has already shipped one major API break (2.x to 3.x removed the downloader and tokenizer dependencies and changed every call site used here). Tracking a moving branch on the inference dependency is the same class of risk as tracking a moving model revision, which §5 of `Engines/AGENTS.md` argues against for the weights. This is Task 5's file so I have not changed it.
- The app needs outbound network access for the first-run download. With the sandbox off that is automatic, but it is worth remembering it is the only network the app ever uses.

**For Task 1 (`RewriteCore`), a minor observation:** `ModelSpec` declares no explicit `public init`, so its synthesized memberwise initializer is internal. `ModelCatalog` is in the same module so nothing is broken today and the engines compile fine, but Task 5 or a test that wants to construct a `ModelSpec` from the app target will not be able to.

**A bug found while double-checking delete completeness.** The lead asked whether "delete the model" really removes everything. It did not. `HubCache` scatters a repository across four locations and three of them sit outside `models--org--name/`: `.metadata/models--org--name/` (a sibling, not a child), `.locks/models--org--name/...` (`HubCache.lockPath(for:)` mirrors any cached path under a top-level `.locks` tree), and our own `.ready/` marker. The original `delete(_:)` removed the repo directory, the metadata directory and the marker, but left the lock tree behind.

Fixed. `delete(_:)` now removes all four, and a new `residualBytes(for:)` measures the same four so the assertion is checkable rather than asserted in prose. `directorySize` was also fixed to count a plain file, because `FileManager.enumerator(at:)` returns nil for a non-directory and the `.ready` marker would otherwise always measure as zero — which would have made `residualBytes` report a clean delete that was not. The leak was a few kilobytes, which is exactly why it would have gone unnoticed: the gigabytes do disappear, so a manual test looks like it passed. Recorded in `Engines/AGENTS.md` §4.

**Unexercised paths worth a second pair of eyes at integration time:**

- `UnreachableDownloader` should never be called. If its error ever surfaces, a `ModelConfiguration` lost its `.directory` id somewhere.
- A second caller joining an in-flight download through `ModelDownloader.inFlight` receives no progress callbacks, only the final URL. The engine's own `Store` dedupe means this is unlikely to be user-visible, but the Settings UI should not assume progress always arrives.
- `AppleEngineError.busy` maps `concurrentRequests`, which should be unreachable because `RewriteCoordinator` owns one transaction. If it shows up, the coordinator's single-transaction invariant has a hole.
