# Engines — decisions

`MLXEngine` (local weights) and `AppleFoundationEngine`, both `RewriteCore.RewriteEngine`. Verified against mlx-swift-lm **3.31.4**, swift-huggingface 0.10.1, swift-transformers 1.3.4, macOS 27.0 SDK / 26.0 target. Derivations are in source comments.

## Build and test
MLX compiles ~40 `.metal` kernels *before* Swift type-checking, so a missing toolchain and a Swift mistake look identical from the top of the log. `error: cannot execute tool 'metal' due to missing Metal Toolchain` → `xcodebuild -downloadComponent MetalToolchain`. The first build takes minutes and is cached in `.build`; **do not `swift package clean`** casually.

**`swift test` builds every test target in the package** — another agent mid-RED breaks your runner and it reads as your bug. Isolate with the two lines below. `swift test --skip-build` is not a substitute: it loads every bundle and dies on whichever is stale.

```bash
swift build --target EnginesTests
xcrun xctest .build/out/Products/Debug/EnginesTests.xctest
```

## Verified mlx-swift-lm 3.x surface
3.x dropped its own downloader and tokenizer; we supply both. There is no `loadModel(id:)`.

```swift
LLMModelFactory.shared.loadContainer(from: URL, using: any TokenizerLoader)  // ModelFactory.swift:201
ChatSession(_ model: ModelContainer, generateParameters: GenerateParameters) // ChatSession.swift:177
session.streamResponse(to: [Chat.Message]) -> AsyncThrowingStream<String,_>  // :497 — yields DELTAS
container.encode(_: String) async -> [Int]                                   // ModelContainer.swift:226
GenerateParameters(maxTokens: Int?, maxKVSize: Int?, temperature: Float)     // Evaluate.swift:54
```

`streamResponse(to:)` with a bare `String` is **ambiguous** between two all-defaulted overloads — pass `[Chat.Message.user(p)]`. The `#hubDownloader()` / `#huggingFaceTokenizerLoader()` macros are avoided on purpose: they force a "trust this macro plugin" prompt on a fresh checkout, and the first points at the shared `~/.cache/huggingface`.

## Never substitute a Qwen3.5 model
Default is `mlx-community/Qwen3-4B-Instruct-2507-4bit`: the 2507 refresh split Instruct from Thinking, so there is no thinking mode to forget to disable. Qwen3.5 is vision-language, thinking-on-by-default, and loads via `mlx_vlm`. **The trap is that it compiles and produces plausible output** — the registry ships the entries below — so the only symptom is every rewrite running ~10x slower, which reads as "the app is slow". Reverted twice by people reading download counts; recency is not an argument.

| Already in `LLMModelFactory.swift` | |
|---|---|
| `LLMRegistry.qwen3_5_2b_4bit`, `qwen3_6_27b_4bit` | ready-made and wrong |
| type keys `"qwen3_5"`, `"qwen3_5_moe"`, `"qwen3_5_text"` | registered, so a checkpoint loads without complaint |

## Deleting a model must clear four locations
`HubCache` scatters one repo across four, and three are **not** under `models--org--name/`:

| Path under `ModelStore.root` | Written by |
|---|---|
| `models--org--name/` (`blobs/`, `refs/`, `snapshots/`) | `HubCache.repoDirectory` :114 |
| `.metadata/models--org--name/` — a sibling | `.metadataDirectory` :129 |
| `.locks/models--org--name/` | `.lockPath(for:)` :153 |
| `.ready/models--org--name` | ours |

`delete` and `residualBytes` both walk `locations(for:)`; add a fifth there or the leak assertion stops being one. Removing only the first looks correct — the gigabytes do go — and leaks the lock and metadata trees forever. `byteCount` handles a **plain file**, because `FileManager.enumerator(at:)` returns nil for non-directories and `.ready` is a file: enumerator-only, it reports a clean delete that was not clean.

## Seams, and rules with teeth
Everything untestable sits behind a protocol: `ModelFetcher` → `HubModelFetcher`, `TokenProducer` → `MLXTokenProducer` + `TransformersTokenizerBridge`, `AppleSystemModel` → `SystemLanguageModelAdapter`. Real conformers translate and hold **no decisions** — `prepare` resolves the snapshot and hands it to `load(from:)`, so the producer never looks one up. Add an `if` to an adapter and it belongs on the tested side. Manual-only: the download, weights loading, inference quality, Apple Intelligence switched off.

- **Pinned commit, never a branch, never a defaulted parameter; build engines with `MLXEngine(spec:)`.** A moving `main` swaps weights under an install already proven to load and `.ready` still matches, because the revision string never changed. `ModelCatalog` is the only record of which weights were tested; an empty revision throws.
- **`.ready` means *loaded once*, not *downloaded*.** Only a completed load marks it; `download` clears it before touching the blobs.
- **A `.ready` marker whose snapshot is gone throws and clears itself.** Trusting it turns a deleted snapshot into a failure at generation time on every hotkey press, naming the wrong thing; clearing it lets the next `prepare` re-download.
- **MLX gives deltas, Apple gives snapshots.** `MLXEngine` accumulates; `AppleFoundationEngine` must **not** — that concatenates the output to itself on every token.
- **Apple availability is re-read on every request.** It is a System Settings toggle a user can flip between two hotkey presses.
- **`SystemLanguageModel` only, never `PrivateCloudComputeLanguageModel`** — sits right beside it, better output, sends the text to Apple's servers.
- **Never log prompts or output.** Type names only; `OSLog` persists. Subsystem from `Bundle.main.bundleIdentifier`, never a literal.
- `TransactionBox` uses a lock, not an actor, so `stream()` then `cancel()` on the next line finds the task registered.
- `ChatSession` fresh per rewrite (reuse keeps the last selection resident); the prompt goes in as one user message with no `instructions:`.
- `com.apple.security.cs.allow-jit` is required, or the app crashes the first time a model loads.
