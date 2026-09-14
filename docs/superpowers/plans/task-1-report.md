# Task 1 report: RewriteCore package

**Status: DONE**

## Deviation from the literal spec (flagged as instructed)

The plan's Task 1 bullets say `swift-tools-version 6.0` **and** `platform .macOS(.v26)`. These two are mutually incompatible on this toolchain: `.macOS(.v26)` is only available starting with `PackageDescription` **6.2**. Building with `// swift-tools-version: 6.0` fails immediately with:

```
error: 'v26' is unavailable
note: 'v26' was introduced in PackageDescription 6.2
```

I resolved this by setting `// swift-tools-version: 6.2` (the minimum that unblocks `.v26`, not the toolchain's latest) and kept `.macOS(.v26)`, because the macOS 26 deployment target is a Global Constraint repeated throughout the plan and load-bearing for the rest of the app (FoundationModels, etc.), while the exact tools-version number is not consumed by any other task's code. Everything else about the manifest matches the spec: one library product `RewriteCore`, one test target, zero external dependencies, Swift 6 language mode (the default under tools-version 6.2).

This was verified as a real, reproducible compiler error (not the anticipated Xcode-license issue) before I made the change; see Build/Test evidence below.

No other signature in the "Shared interfaces" section required any change. Every type is implemented as written, verbatim.

## Files created

```
RewriteCore/Package.swift
RewriteCore/Sources/RewriteCore/RewriteEngine.swift      (EngineID, RewriteRequest, RewriteEvent, EngineAvailability, RewriteEngine)
RewriteCore/Sources/RewriteCore/Presets.swift             (Preset)
RewriteCore/Sources/RewriteCore/PromptBuilder.swift       (PromptBuilder, safetyFrame verbatim)
RewriteCore/Sources/RewriteCore/OutputValidator.swift     (ValidationFailure, OutputValidator)
RewriteCore/Sources/RewriteCore/ModelCatalog.swift        (ModelSpec, ModelCatalog)
RewriteCore/Sources/RewriteCore/Settings.swift            (AppSettings)
RewriteCore/Tests/RewriteCoreTests/CoreTests.swift        (the 5 required tests, no more)
RewriteCore/AGENTS.md
RewriteCore/CLAUDE.md
docs/superpowers/plans/task-1-report.md                   (this file)
```

## Compilation and test evidence

Confirmed the license concern flagged in my brief does not apply on this machine: `swift build`/`swift test` run cleanly with no Xcode-license error at any point.

TDD sequence actually followed:
1. Wrote `Package.swift` + `CoreTests.swift` first, against the not-yet-existing API.
2. `swift test` failed for real reasons twice in sequence: first the tools-version/`.v26` conflict above, then (after fixing that) `error: target 'RewriteCore' referenced in product 'RewriteCore' is empty` because no source files existed yet. Both are genuine RED states, not the license issue.
3. Wrote the six source files.
4. `swift build` and `swift test` both went green on the first attempt after that.
5. Re-verified with a full clean rebuild (`rm -rf .build && swift build`): zero warnings, zero errors, exit 0.
6. Re-ran `swift test` again after later doc-comment edits (removing stray em dashes from comments): still 5/5 passing.

Final fresh run, this session:

```
$ swift test
Build complete! (5.28 sec)
◇ Suite "RewriteCore" started.
✔ Test "ModelCatalog.all has exactly one default, and it is qwen4B" passed
✔ Test "Preset.builtInStyles has exactly 5 entries with unique names" passed
✔ Test "OutputValidator.validate rejects empty output and output far longer than the source, accepts a reasonable rewrite" passed
✔ Test "PromptBuilder keeps the safety frame ahead of an injection string and delimits it as data" passed
✔ Test "OutputValidator.clean strips a conversational preamble, wrapping quotes, and stray selected_text tags" passed
✔ Suite "RewriteCore" passed after 0.001 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

Exactly 5 tests, matching the 5 required by the brief. Used swift-testing (`import Testing`, `@Test`, `#expect`, `#require`), available on this toolchain (Swift 6.4 / Xcode 27), per the brief's preference order.

## Notable implementation decisions beyond the literal spec (all additive, none change a given signature)

- **Fixed UUIDs for built-in presets.** `Preset.quickImprove` and each `Preset.builtInStyles` entry use hardcoded UUID literals instead of `UUID()`, so their identity is stable across process launches and Codable round-trips through `AppSettings`. Using `UUID()` would silently break both. Full rationale in `RewriteCore/AGENTS.md`.
- **`AppSettings` is actually `UserDefaults`-backed.** The Shared Interfaces block only shows the four `@Published` properties and `resetQuickImprove()`, but the root `AGENTS.md` (already in the repo) documents `Settings.swift` as "UserDefaults-backed," so I implemented real persistence (JSON-encoded `Preset`/`[Preset]`, raw-value `EngineID`, and the bundle-ID array) rather than leaving it in-memory-only for a later task to redo. `AppSettings.shared` still works exactly as specified; I added `public init(store: UserDefaults = .standard)` so tests/previews can inject an isolated store. This is additive, not a change to the given `shared` signature.
- **`excludedBundleIDs` default list**: 1Password (both bundle IDs), Bitwarden, LastPass, Dashlane, Keychain Access, and `com.apple.SecurityAgent`. Plan only said "1Password et al"; this is a reasonable, user-editable default, not a hard security boundary (the real guard is Task 2's per-capture secure-field/secure-role check).
- **`ModelSpec.displayName` / `.blurb` wording**: written to match the facts already established in the root `AGENTS.md` (2.3 GB / ~2s for qwen4B; 17.2 GB / ~5s / 18-20 GB RAM for qwen30B; Apple's guardrail-refusal problem), so Settings won't show text that contradicts the architecture doc.
- **`OutputValidator.clean`'s preamble heuristic** strips a leading single-line, colon-terminated lead-in (checked against a short list of conversational openers like "sure", "here", "of course") followed by a blank line, rather than a hardcoded literal match on one exact sentence. It correctly handles the exact required case (`"Sure! Here's an improved version:\n\n"`) plus the general class of similar preambles, and does not fire on the 5x-length test's filler text (verified: no false-positive strip there).

## AGENTS.md / CLAUDE.md

`RewriteCore/CLAUDE.md` is exactly `@AGENTS.md`, one line.

`RewriteCore/AGENTS.md` covers, as durable decision records with rationale: what the package is for; why zero dependencies and no AppKit/SwiftUI (with a note on why `import Combine` for `ObservableObject` does not violate that); why `RewriteEvent` is cumulative-snapshot-shaped (Apple's streaming API is already snapshot-shaped, and dropped/coalesced UI updates only lose data under a delta model, not a snapshot model); why the safety frame is structurally separated from the user-editable instruction (prompt injection via untrusted selected text, plus why `OutputValidator` is the necessary second layer, not a redundant one); why the model catalog defaults to Qwen3-4B-Instruct-2507 and must never point at a Qwen3.5 model, spelled out mechanism-by-mechanism (vision-language / `mlx_vlm` not `mlx_lm` / thinking-mode-on-by-default with no working `/nothink` / ~10x slowdown with no loud error, so the danger is silence, not a crash); and the five constants (8,000-char cap, temperature 0.2, the output-budget formula, 8,192 context cap, 3.0 length-ratio reject), each with the reasoning behind the specific number, not just a restatement of it. Also documents the fixed-UUID and `UserDefaults`-backing decisions above. Checked for the banned AI-tell words and em dashes; none present.

## Everything from the brief, verified against source

- `Package.swift`: swift-tools-version 6.2 (see deviation above), platform `.macOS(.v26)`, one library product `RewriteCore`, one test target, zero dependencies. ✅.
- Every type in "Shared interfaces" implemented verbatim (`EngineID` raw values, `RewriteRequest`, `RewriteEvent`, `EngineAvailability`, `RewriteEngine`, `Preset`, `PromptBuilder`, `ValidationFailure`, `OutputValidator`, `ModelSpec`, `ModelCatalog`, `AppSettings`). ✅.
- `PromptBuilder.safetyFrame` matches the required wording character-for-character (copy-checked against the brief, not retyped from memory a second time). ✅.
- `build()` composes safetyFrame, then instruction, then `<selected_text>`-delimited text, in that order. ✅.
- `ModelCatalog.all`: exactly 3 entries, `.qwen4B` repoID `mlx-community/Qwen3-4B-Instruct-2507-4bit` / `2_300_000_000` bytes / `isDefault: true`; `.qwen30B` repoID `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` / `17_200_000_000` bytes / `isDefault: false`; `.apple` repoID `""` / `0` bytes / `isDefault: false`. Honest blurbs on all three (speed vs quality vs zero-download-but-can-refuse). ✅.
- Exactly the 5 required tests, no more. ✅.

## Addendum: post-report follow-up (2026-09-14)

Two things came in from team-lead after this report was first submitted.

**Re-verification after the Xcode license was accepted.** Ran a full clean rebuild with `dangerouslyDisableSandbox: true` as instructed:

```bash
cd /Users/kabara/Desktop/Improve/RewriteCore && rm -rf .build && swift test
```

`Build complete! (8.87 sec)`, 5/5 tests passing. This matches every prior run in this report; the license was never actually blocking anything on this machine, and that's now confirmed twice over, once before and once after the license was accepted, so the result did not change. Ran it once more after the rename edits below, clean build, 5/5 passing again.

**The Improve → Everest product rename.** Updated documentation prose only, no directories touched or renamed. Changed:

- `RewriteCore/AGENTS.md`: four sibling-directory references (`Improve/Engines`, `Improve/Overlay`, `Improve/Selection`, `Improve/Replacement`) to `Everest/Engines`, `Everest/Overlay`, `Everest/Selection`, `Everest/Replacement`, matching the app-target folder name in the root `AGENTS.md`'s layout diagram.
- `Settings.swift`'s doc comment: "the `Improve` app target" to "the `Everest` app target."

Left unchanged, per the three protected exceptions team-lead called out (and confirmed already correct in the original report): `PromptBuilder.safetyFrame`'s "You improve selected writing," `Preset.quickImprove`, and the built-in style named `"Improve"`.

Also left unchanged, as a judgment call outside the stated scope of "user-facing strings and documentation prose": the four `UserDefaults` key strings in `Settings.swift`'s `Keys` enum (`"improve.settings.engineID"`, `.quickImprove`, `.styles`, `.excludedBundleIDs"`). These are internal storage identifiers, never shown to a user, not documentation prose, and since no shipped build exists yet to have persisted data under them, there's no compatibility cost either way; renaming them wasn't asked for, so I left them alone rather than guessing. Flagging so team-lead can say if they should change too.

## Addendum 2: missing public initializers (2026-09-14)

Team-lead found, during Task 3 integration, that `ModelSpec` has no explicit `public init`, so its memberwise initializer defaults to internal and the app target could not construct one. Asked me to audit every public type in `RewriteCore` for the same gap.

Audit method: `grep -n "^public \(struct\|enum\|class\|protocol\)" Sources/RewriteCore/*.swift` to enumerate every top-level public type, then checked each by hand.

- `ModelSpec` (struct): no init. **Fixed** — added `public init(id:repoID:displayName:approxBytes:blurb:isDefault:)`, same parameter names/order/types as the stored properties, so `ModelCatalog.all`'s existing labeled-argument call sites needed no changes.
- `RewriteRequest` (struct): already had `public init(text:preset:)`. No change needed.
- `Preset` (struct): already had `public init(id:name:subtitle:instruction:)`. No change needed.
- `AppSettings` (class): already had `public init(store:)`; classes don't get an implicit memberwise init in the first place, so this class was never at risk. No change needed.
- `EngineID`, `RewriteEvent`, `EngineAvailability`, `ValidationFailure` (enums): enum cases are directly constructible from outside the module at the enum's own access level; this class of bug is struct-only. No change needed. (`EngineID` also gets a compiler-synthesized `public init?(rawValue:)` since it's a public `RawRepresentable` enum.)
- `ModelCatalog`, `OutputValidator`, `PromptBuilder` (enums used only as static-member namespaces, no cases): nothing to construct. No change needed.
- `RewriteEngine` (protocol): no initializer to provide; each conforming type supplies its own.

So `ModelSpec` was the only real gap. Added a short paragraph to `RewriteCore/AGENTS.md`'s "Smaller decisions" section documenting the trap (public struct + internal memberwise init) so a future added struct doesn't repeat it.

No signature changed, no existing behavior altered; the new initializer's parameter list matches the struct's existing stored-property list exactly.

Verification, fresh run with `dangerouslyDisableSandbox: true`, after the `ModelSpec` fix and the doc update:

```bash
$ cd /Users/kabara/Desktop/Improve/RewriteCore && swift test
Build complete! (0.20 sec)
✔ Test "ModelCatalog.all has exactly one default, and it is qwen4B" passed
✔ Test "Preset.builtInStyles has exactly 5 entries with unique names" passed
✔ Test "OutputValidator.validate rejects empty output and output far longer than the source, accepts a reasonable rewrite" passed
✔ Test "PromptBuilder keeps the safety frame ahead of an injection string and delimits it as data" passed
✔ Test "OutputValidator.clean strips a conversational preamble, wrapping quotes, and stray selected_text tags" passed
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

5/5 passing. Status remains **DONE**.

## Addendum 3: UserDefaults key rename (2026-09-14)

Team-lead confirmed the `everest.settings.*` rename should happen. When I went to make the edit, `Settings.swift`'s `Keys` enum already read `everest.settings.engineID` / `.quickImprove` / `.styles` / `.excludedBundleIDs` on disk — the edit attempt failed with "string to replace not found" because the old `improve.settings.*` text was already gone. Someone else in the team already applied it before my edit landed. Confirmed by re-reading the file; the content matches exactly what was asked for, so nothing further to do here.

Fresh verification after confirming this, `dangerouslyDisableSandbox: true`:

```bash
$ swift test
Build complete! (0.25 sec)
✔ Test "ModelCatalog.all has exactly one default, and it is qwen4B" passed
✔ Test "Preset.builtInStyles has exactly 5 entries with unique names" passed
✔ Test "PromptBuilder keeps the safety frame ahead of an injection string and delimits it as data" passed
✔ Test "OutputValidator.validate rejects empty output and output far longer than the source, accepts a reasonable rewrite" passed
✔ Test "OutputValidator.clean strips a conversational preamble, wrapping quotes, and stray selected_text tags" passed
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

5/5 passing. Status remains **DONE**.
