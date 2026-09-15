# Engines — decisions

`MLXEngine` (local weights) and `AppleFoundationEngine`, both `RewriteCore.RewriteEngine`. Verified against mlx-swift-lm **3.31.4**, swift-huggingface 0.10.1, swift-transformers 1.3.4, macOS 27.0 SDK / 26.0 target. Derivations are in source comments.

## Build and test
Root §8 has the isolation and stale-bundle rules; issue this as **one** `&&` command:

```bash
swift build --target EnginesTests && xcrun xctest .build/out/Products/Debug/EnginesTests.xctest
```

Engines-specific: MLX compiles ~40 `.metal` kernels *before* Swift type-checking, so a missing toolchain and a Swift mistake look identical from the top of the log. `error: cannot execute tool 'metal' due to missing Metal Toolchain` → `xcodebuild -downloadComponent MetalToolchain`. The first build takes minutes and is cached in `.build`; **do not `swift package clean`** casually.

## Verified mlx-swift-lm 3.x surface
3.x dropped its own downloader and tokenizer; we supply both. There is no `loadModel(id:)`.

```swift
LLMModelFactory.shared.loadContainer(from: URL, using: any TokenizerLoader)  // ModelFactory.swift:201
ChatSession(_ model: ModelContainer, generateParameters: GenerateParameters) // ChatSession.swift:177
session.streamDetails(to: [Chat.Message]) -> AsyncThrowingStream<Generation,_> // :534 — see below
container.encode(_: String) async -> [Int]                                   // ModelContainer.swift:226
GenerateParameters(maxTokens: Int?, maxKVSize: Int?, temperature: Float)     // Evaluate.swift:54
```

**`streamDetails`, never `streamResponse`.** Same stream; `streamResponse` maps it through `\.chunk` and throws away the one `Generation.info` yielded before `finish()` (`Evaluate.swift:1917`), carrying `stopReason: .stop | .length | .cancelled`. See below. Both take a bare `String` ambiguously across two all-defaulted overloads — pass `[Chat.Message.user(p)]`. The `#hubDownloader()` / `#huggingFaceTokenizerLoader()` macros are avoided on purpose: they force a "trust this macro plugin" prompt on a fresh checkout, and the first points at the shared `~/.cache/huggingface`.

## A truncated rewrite is never a rewrite
`TextBridge` captures 8,000 characters; `EngineLimits` allowed 768 output tokens. Two sensible constants, never reconciled. Past ~3,000 characters the decoder stopped at `maxTokens` mid-word, and **every guard downstream checks the wrong direction** — `OutputValidator` rejects output over 3× the input and has no lower bound — so the fragment validated cleanly and replaced the selection. No undo; `.success` dismisses itself in 1.2 s. Three layers now:

- **`outputBudget`'s ceiling is derived**, `contextCap - inputTokens`, never a constant of its own: `1.4 × inputTokens` is the anti-rambling guard and it already scales, while a flat ceiling only ever binds on long inputs, which is exactly where it destroys text. Also stops `maxTokens` overrunning the `maxKVSize` the same settings ask for.
- **`GenerationStop.budgetExhausted` → `GenerationError.truncated`** in `MLXEngine`. The `.length` stop reason: exact, no inference.
- **`OutputCompleteness`** — source ends a sentence, output does not. Backstop for `AppleFoundationEngine`, which has no stop reason or token count at all, and for an mlx upgrade that stops reporting one. **Not a length ratio, and do not add one:** `Concise` means "significantly shorter", so an honest rewrite is routinely 40% of its source, the proportion a truncation also gives. The signal is where the text stops. Fails open on a fragment source, or refusing every heading and unpunctuated note becomes the new bug.

## Never substitute a Qwen3.5 model
Default is `mlx-community/Qwen3-4B-Instruct-2507-4bit`: the 2507 refresh split Instruct from Thinking, so there is no thinking mode to forget to disable. Qwen3.5 is vision-language, thinking-on-by-default, and loads via `mlx_vlm`. **The trap is that it compiles and produces plausible output** — the registry ships the entries below — so the only symptom is every rewrite running ~10x slower, which reads as "the app is slow". Reverted twice by people reading download counts; recency is not an argument.

| Already in `LLMModelFactory.swift` | |
|---|---|
| `LLMRegistry.qwen3_5_2b_4bit`, `qwen3_6_27b_4bit` | ready-made and wrong |
| type keys `"qwen3_5"`, `"qwen3_5_moe"`, `"qwen3_5_text"` | registered, so a checkpoint loads without complaint |

## Deleting a model must clear four locations
`HubCache` scatters one repo across four, three of them **not** under `models--org--name/`. The paths and their writers are the table on `ModelStore.locations(for:)`; what is not in the code is why it matters. `delete` and `residualBytes` both walk that one list, so add a fifth there or the leak assertion stops being one. Removing only the repo directory looks correct — the gigabytes do go — and leaks the lock and metadata trees forever. `byteCount` handles a **plain file**, because `FileManager.enumerator(at:)` returns nil for non-directories and `.ready` is a file: enumerator-only, it reports a clean delete that was not clean.

## Seams, and rules with teeth
Everything untestable sits behind a protocol: `ModelFetcher` → `HubModelFetcher`, `TokenProducer` → `MLXTokenProducer` + `TransformersTokenizerBridge`, `AppleSystemModel` → `SystemLanguageModelAdapter`. Real conformers translate and hold **no decisions** — `prepare` resolves the snapshot and hands it to `load(from:)`, so the producer never looks one up. Add an `if` to an adapter and it belongs on the tested side. Manual-only: the download, weights loading, inference quality, Apple Intelligence switched off.

- **Pinned commit, never a branch, never a defaulted parameter; build engines with `MLXEngine(spec:)`.** A moving `main` swaps weights under an install already proven to load and `.ready` still matches, because the revision string never changed. `ModelCatalog` is the only record of which weights were tested; an empty revision throws.
- **`.ready` means *loaded once*, not *downloaded*.** Only a completed load marks it; `download` clears it before touching the blobs.
- **A `.ready` marker whose snapshot is gone throws and clears itself.** Trusting it turns a deleted snapshot into a failure at generation time on every hotkey press, naming the wrong thing; clearing it lets the next `prepare` re-download.
- **MLX gives deltas (`TokenEvent.delta`), Apple gives snapshots.** `MLXEngine` accumulates; `AppleFoundationEngine` must **not** — that concatenates the output to itself on every token.
- **Apple availability is re-read on every request.** It is a System Settings toggle a user can flip between two hotkey presses.
- **`SystemLanguageModel` only, never `PrivateCloudComputeLanguageModel`** — sits right beside it, better output, sends the text to Apple's servers.
- **Never log prompts or output.** Type names only; `OSLog` persists. Subsystem from `Bundle.main.bundleIdentifier`, never a literal.
- `TransactionBox` uses a lock, not an actor, so `stream()` then `cancel()` on the next line finds the task registered.
- `ChatSession` fresh per rewrite (reuse keeps the last selection resident); the prompt goes in as one user message with no `instructions:`.
- `com.apple.security.cs.allow-jit` is required, or the app crashes the first time a model loads.
