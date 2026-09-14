# Everest — Architecture and Decisions

Canonical instructions for any AI agent or human working in this repo. Read this file before touching code. Written 2026-09-14.

---

## 0. The documentation convention (follow it, and keep it alive)

**Every directory that contains source files has two files:**

| File | Contents |
|---|---|
| `AGENTS.md` | The real thing. What this directory is for, every non-obvious decision, and **why**. Durable decision records with rationale. |
| `CLAUDE.md` | Exactly one line: `@AGENTS.md`. Nothing else, ever. |

`AGENTS.md` is canonical because it is the tool-agnostic name. `CLAUDE.md` exists only so Claude Code picks it up automatically, and it must never accumulate its own content, because a fact in two files goes stale in one of them.

**If you are an agent working here, you are bound by these rules:**

1. **Read the `AGENTS.md` in every directory you touch before you edit anything in it.** The guards in this codebase look removable and are not.
2. **When you change a decision, update that directory's `AGENTS.md` in the same commit.** A decision record that lags the code is worse than none, because the next agent trusts it.
3. **When you create a new source directory, create both files in it.** No exceptions for "small" directories.
4. **Write rationale, not inventory.** "`PasteboardTransaction` snapshots all types" is a file listing and helps nobody. "Restoring on a fixed delay races the user and silently eats whatever they copied during the rewrite, so the restore is conditional on `changeCount`" is a decision record. A future agent reading only the second one will not break it.
5. **Do not delete a guard because it looks like overkill.** §5 below lists the ones that exist for a specific, already-reasoned cause. If you think one is wrong, say so to the human rather than removing it.

---

## 1. What this app is

A menu-bar app. Select text in any Mac app, press a hotkey, a floating panel streams a locally-generated rewrite, and the selection is replaced when generation finishes. Nothing leaves the machine.

Two hotkeys:

| Hotkey | Behavior |
|---|---|
| `⌘I` | Quick Improve. One saved prompt, one output. No picker. |
| `⌘⇧I` | Choose Style. Pick from a list, then one output. |

Both are user-configurable. `⌘I` is the requested default and it does shadow Italic in every editor while the app runs, which is a known and accepted tradeoff. The recorder warns once.

Full product reasoning lives outside this repo in the Obsidian vault at `08-AI-rewrite-app/`. This file is the engineering record and wins on anything technical.

### A naming trap, before you run find-and-replace

The app was called "Improve" until it was renamed to **Everest**. The word `improve` legitimately survives in three places and must not be swept up in a rename:

1. `PromptBuilder.safetyFrame` begins "You improve selected writing..." — that is the model instruction, not a product name.
2. `Preset.quickImprove` and the user-facing command "Quick Improve" — Everest is the app, Quick Improve is the command it runs.
3. The built-in style named "Improve" in the `⌘⇧I` picker.

A blind `s/Improve/Everest/` produces "You everest selected writing" and silently degrades every rewrite the app makes, with no compile error. Rename by hand or with anchored patterns.

---

## 2. Layout

```
Everest/
├── AGENTS.md              ← you are here
├── CLAUDE.md              → @AGENTS.md
├── project.yml            xcodegen spec, regenerate with `xcodegen generate`
├── RewriteCore/           SwiftPM package. Pure, zero dependencies, `swift test`able.
│   └── Sources/RewriteCore/
│       RewriteEngine.swift   the protocol every engine implements
│       PromptBuilder.swift   safety frame + delimited untrusted input
│       OutputValidator.swift preamble stripping and sanity rejection
│       Presets.swift         Quick Improve + the style list
│       ModelCatalog.swift    the three engines and their real byte sizes
│       Settings.swift        UserDefaults-backed, @MainActor
└── Everest/               the .app target. macOS integration only.
    ├── App/               lifecycle, status item, hotkeys, RewriteCoordinator
    ├── Selection/         reading the selection out of other apps
    ├── Replacement/       writing it back, safely
    ├── Engines/           MLX and Apple adapters, model download
    ├── Overlay/           the floating panel
    └── Settings/          settings window and onboarding
```

**Why the split:** everything in `RewriteCore` runs under `swift test` in about two seconds without launching an app or granting a permission. Everything in `Everest/` needs a real Mac, a real permission grant, and a real other-app to point at. Keeping the testable part genuinely dependency-free is what makes the five core tests worth running. Do not import AppKit into `RewriteCore`.

---

## 3. Architecture decisions

### One actor owns one transaction

`RewriteCoordinator` is an `actor` and holds exactly one in-flight rewrite. Pressing a hotkey again cancels the previous generation. Without this you get two streams racing to replace the same selection.

UI work is `@MainActor`. Accessibility calls and model decoding must not block it.

### Engines stream cumulative snapshots, not token deltas

`RewriteEvent.outputSnapshot(String)` carries the whole output so far, every time.

Two reasons. Apple's `FoundationModels` API is already snapshot-shaped (`streamResponse` yields partial values, not deltas), so deltas would mean diffing Apple's output just to re-accumulate it downstream. And a dropped or coalesced UI update loses nothing with snapshots, where with deltas it corrupts the result permanently. MLX gives deltas natively and `MLXEngine` accumulates them before emitting.

### The engine protocol has two real implementations, which is what earns it

`RewriteEngine` is not speculative abstraction. `MLXEngine` and `AppleFoundationEngine` both exist from day one and behave differently enough (download vs no download, refusals vs no refusals, deltas vs snapshots) that the protocol is doing real work. Do not add a third implementation without a user-visible reason.

### Native Swift, not Tauri or Electron

Almost all the difficulty here is macOS integration: Accessibility, focus, panels, pasteboard transactions, synthetic events, permissions, memory pressure, Metal inference. A cross-platform shell would add a bridge at exactly the hardest boundary and improve nothing.

---

## 4. The model decision, with evidence

**Default: `mlx-community/Qwen3-4B-Instruct-2507-4bit`.**

This has been reverted to a Qwen3.5 model twice by people reading download counts. Do not do it a third time. The evidence:

| Candidate | Verdict |
|---|---|
| `Qwen3-4B-Instruct-2507-4bit` (~2.3 GB) | **Default.** Text-only. Non-thinking *by design*: the 2507 refresh split Instruct and Thinking into separate models, so there is no mode to forget to disable. Loads via `mlx_lm`, so the plain `LLMModelFactory` path works. Apache 2.0. About 2s for a paragraph on an M4 Pro. |
| `Qwen3-30B-A3B-Instruct-2507-4bit` (~17.2 GB) | **Quality option, user-selectable.** Mixture-of-experts: 31B total, ~3B active per token, so decode speed tracks the 3B. About 5s per paragraph. Needs 18-20 GB resident, which is fine on a 48 GB Mac and not on a 24 GB one. |
| Apple Foundation Models | **Zero-download option, not the default.** Its guardrails can terminate a stream mid-sentence with a vague error, and cannot be disabled. False refusals are reported on ordinary text about a death or on routine political content. A rewrite tool that sometimes refuses to rewrite is one you stop reaching for. |
| **Any Qwen3.5 model** | **Disqualified.** It is a vision-language model (`Image-Text-to-Text` pipeline tag, vision encoder you download and never use), **thinking mode is on by default** and the Qwen3 `/nothink` toggle does not work on it, and the MLX builds load through `mlx_vlm`, not `mlx_lm`, so `LLMModelFactory` is the wrong entry point. Shipping it makes every rewrite roughly 10x slower through reasoning tokens the user never sees. |

Newer and more-downloaded, and still the wrong tool. Recency is not an argument.

**The model is never bundled in the .app.** It downloads to `~/Library/Application Support/Everest/Models/<repoID>/` on first run with visible progress, and can be deleted from Settings. Bundling 2.3 GB into an app is hostile, and bundling 17.2 GB is absurd.

Pin an exact revision rather than a moving branch, and verify the model loads before marking it ready. A half-downloaded model that loads and emits garbage is a confusing afternoon.

---

## 5. Guards that must not be simplified away

Each of these exists for a cause that was already reasoned through. The per-directory `AGENTS.md` files carry the detail.

| Guard | What breaks without it |
|---|---|
| Secure-field refusal before every capture | A password gets read into an LLM prompt. |
| Prompt-injection frame around the selection | Text containing "ignore previous instructions" changes app behavior. The safety frame is deliberately NOT user-editable; only the style instruction is. |
| Output validation before replacement | The user's email gets replaced with "Sure! Here's an improved version:". |
| Conditional pasteboard restore on `changeCount` | Anything the user copies during a rewrite is silently destroyed. |
| Target revalidation before writing | Three seconds is long enough to click into another window. Clobbering the wrong text is unrecoverable. |
| Never trimming captured text | Silently alters what the user selected. Electron's off-by-one is a range problem and belongs at the range level. |
| Escape event monitor torn down after each transaction | A leaked global key monitor watches every keystroke the user ever types. |
| Only the current transaction's original kept in memory | Anything more is an undeclared history of recent selections, some of which are private. |
| No content in logs | Selected text in `OSLog` defeats the entire local-only premise. |

---

## 6. Hard platform facts

- **The sandbox is off, and the Mac App Store is not available to this app.** Under App Sandbox, `AXUIElementSetAttributeValue` and `AXUIElementCopyElementAtPosition` do not function even with Accessibility granted, the permission prompt never appears, and `AXIsProcessTrusted()` returns false permanently. Both halves of this product are blocked. Rectangle, BetterTouchTool and Hammerspoon all ship outside the Store for this reason. Do not add `com.apple.security.app-sandbox`.
- **Accessibility permission is required** and the app is useless without it. Onboarding gates on it.
- **A non-activating `NSPanel` is not key and receives no key events.** Escape needs an event monitor. If you "fix" the panel to a normal `NSWindow`, the source app loses focus and the selection evaporates.
- **Replacement is impossible in Terminal, Ghostty, iTerm, PDFs and ordinary web prose.** There is no editable buffer behind the selection. These fall back to copy-only, and that is correct behavior, not a bug to fix.
- Minimum macOS 26.0, Apple Silicon only.

---

## 7. Build and run

```bash
cd ~/Desktop/Everest
xcodegen generate                       # after any change to project.yml
open Everest.xcodeproj                  # then ⌘R
```

Headless:

```bash
xcodebuild -project Everest.xcodeproj -scheme Everest \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/everest-dd build
```

Core tests, no app needed:

```bash
cd RewriteCore && swift test
```

Gotchas:

- **The Metal Toolchain is a separate download on Xcode 26+.** MLX pulls in `Cmlx`, which compiles about forty `.metal` kernels during a normal build, so without the component the build dies before Swift type-checking with `error: cannot execute tool 'metal' due to missing Metal Toolchain`. Confusingly `xcrun -f metal` still resolves to a binary; only invoking it fails. Fix: `xcodebuild -downloadComponent MetalToolchain`. This is also why an MLX project that built fine under an older Xcode suddenly stops.
- **A local package's `path:` in `project.yml` resolves relative to the spec file, not the working directory.** Getting this wrong gives the unhelpful `Spec validation error: Invalid local package "RewriteCore"`. Keeping `project.yml` at the repo root makes the relative path correct.
- **An app target needs an explicit `info:` block in `project.yml`.** Without one the build fails with `Build input file cannot be found: .../Info.plist`, which reads like a missing file rather than a missing generator directive.
- **`xcodegen generate` must be re-run after renaming or adding a source file.** A stale project reports `Build input file cannot be found` for the old filename.
- **Ignore the `DVTCoreDeviceCore` plug-in failure and the `CoreSimulator is out of date` warning.** They appear on every `xcodebuild` invocation here, only disable iOS simulator support, and are harmless for a macOS-only target. Do not go chasing them.
- Agent sandboxes block the Swift toolchain's access to system headers. Bash calls that compile need `dangerouslyDisableSandbox: true`.
- After moving the repo or adding a file, a stale `.build` causes "SwiftShims/module cache path" errors. Fix with `swift package clean`.
- `⌘R` in Xcode uses Xcode's own DerivedData, not `/tmp/everest-dd`. A fix that "did not take" is usually stale modules there: Product ▸ Clean Build Folder (⇧⌘K).
- **Accessibility permission is keyed to the code signature.** Re-signing with a different identity makes macOS treat the app as new and you must re-grant. Sign consistently with the same Apple Development identity during development, and expect to re-grant after the first switch.

---

## 7a. Bundle identifier and logging

The bundle identifier is **`com.kabrapratik.Everest`** (`bundleIdPrefix: com.kabrapratik` plus target name `Everest` in `project.yml`).

Never hardcode it as an `OSLog` subsystem. Every logger in this codebase uses:

```swift
Logger(subsystem: Bundle.main.bundleIdentifier ?? "Everest", category: "...")
```

One half of the app once used a hand-written `com.everest.app` while the identifier was `com.kabrapratik.Everest`. Nothing fails visibly when this drifts: the code compiles, the app runs, and `log stream --subsystem ...` simply returns nothing forever, with no error explaining why. Deriving the subsystem from the bundle makes the drift impossible.

Two related rules that already cost time once each: Accessibility permission is keyed to the code signature, so changing the signing identity makes macOS treat the app as new and the user must re-grant. And `com.apple.security.cs.allow-jit` is required in the entitlements because Hardened Runtime is on and MLX JIT-compiles Metal shaders at runtime; without it the app builds and launches fine and then crashes the first time a model loads, which looks like an MLX bug and is not.

---

## 8. Dependencies

| Package | Why |
|---|---|
| `sindresorhus/KeyboardShortcuts` | User-recordable global hotkeys with a SwiftUI recorder, persistence, and collision warnings, in about fifteen lines. It wraps Carbon `RegisterEventHotKey`, so the app does not need Input Monitoring permission merely to notice a keypress. MIT. |
| `ml-explore/mlx-swift-lm` | Local inference on Apple Silicon. Metal-backed, unified-memory native. |
| Apple `FoundationModels` | System framework, no package. Availability-gated at runtime, not compile time. |

Do not add a dependency that a few lines of stdlib would cover. Every one of these earns its place by replacing real work.
