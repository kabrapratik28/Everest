# RewriteCore: Decisions and Rationale

Canonical instructions for this directory. Read the root `AGENTS.md` first. Written 2026-09-14, Task 1 of the MVP plan.

## What this package is

The non-UI, non-OS-integration brain of the app: prompt building, output validation, presets, the model catalog, and persisted settings. `Engines` implements `RewriteEngine`, `Overlay` renders `RewriteEvent`s, `TextBridge` hands this package raw text and gets validated text back — a rule about prompts, validation, presets, or models changes here first and every consumer sees the same fix.

## Zero dependencies, stays pure

Tests run in ~1s: no Accessibility, no window server, no model download. `import Combine` in `Settings.swift` is not a violation of that — `ObservableObject`/`@Published` impose no GUI requirement. `AppKit`/`SwiftUI` would; never import either here.

## Why `RewriteEvent` uses cumulative snapshots, not deltas

Apple's streaming API yields a full partial response at every step, not a delta. The overlay updates many times a second; a dropped snapshot update just renders a later, still-correct string, where a dropped delta permanently loses a chunk of text. `MLXEngine`, which does get real token deltas, accumulates them into a running string before emitting.

## Why the safety frame is separate from the user-editable instruction

`PromptBuilder.safetyFrame` is fixed; `Preset.instruction` is the only user-editable string. `build` always orders frame, then instruction, then the untrusted selected text, delimited in `<selected_text>` tags — selected text can come from anywhere and could contain "ignore previous instructions," and weak 4B-class models don't reliably resist that. Never let `instruction` precede `safetyFrame`, or merge the two into one editable string. `OutputValidator` is the second, independent layer behind this one.

Injection containment is a structural consequence of the fixed template, not a separate detect-and-neutralize code path. If that test ever fails, restore the ordering — don't add detection logic.

## The model catalog, and why it must never point at Qwen3.5

`ModelCatalog.all` is the fixed list of models this app will ever run. Default is `.qwen4B`; `ModelSpec.isDefault` must stay true only there — it's been changed by mistake twice already by someone reading download counts instead of model behavior.

Any Qwen3.5 model is disqualified: it's a vision-language model (loads via `mlx_vlm`, not the `mlx_lm` path `MLXEngine` is written against), thinking-on-by-default with no working `/nothink`, and none of this fails loudly — it downloads and runs, just ~10x slower with hidden reasoning tokens `OutputValidator` doesn't strip. A silent regression is worse than a crash, which is why this is stated this strongly here and in root `AGENTS.md`.

`ModelSpec.revision` pins an exact commit SHA per root `AGENTS.md` §4 — never a branch, so the weights tested against are the weights a later run actually downloads. `.apple` has no repo, so it carries a fixed sentinel string instead of a real revision: still non-empty, satisfying the shared invariant without implying a pin that doesn't exist.

## Smaller decisions worth knowing about

**Built-in presets use fixed, hand-written UUIDs**, not `UUID()` — a fresh one on every access would break Codable round-tripping through `AppSettings` and SwiftUI list identity. `quickImprove` and `builtInStyles`'s "Improve" entry share instruction text on purpose but deliberately not a UUID: two independently user-editable fields.

**`AppSettings` is `UserDefaults`-backed with an injectable store** (`init(store: UserDefaults = .standard)`), so a test or preview never touches the real user's defaults. `.shared` still works exactly as the plan specifies.

**Every public struct has an explicit `public init`.** Swift's synthesized memberwise init defaults to internal access even on a public struct — it compiles here and is still unconstructable from another module. A prior attempt let `ModelSpec` skip this and construction from `Engines` failed silently.

**`RewriteRequest`, `RewriteEvent`, `EngineAvailability`, and `RewriteEngine`** (`RewriteEngine.swift`) have no driving test. They pass YAGNI — `Engines`, `Overlay`, and `TextBridge` are three real consumers that need them to compile — and need no test under the Iron Law, since pure shape with no branching logic has no failure mode a test could catch. The moment any of them grows real behavior, that behavior gets a test first.

**`AppSettings` is `@MainActor`; tests touching it must be too**, or Swift 6 strict concurrency rejects the call.

## Running the tests

```bash
cd RewriteCore && swift test
```

Twelve tests across `PromptBuilder`, `OutputValidator`, `Preset.builtInStyles`, and `ModelCatalog` (`CoreTests.swift`), plus `AppSettings`'s round-trip in its own file. Give new behavior its own test file.
