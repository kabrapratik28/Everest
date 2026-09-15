# Everest — architecture and decisions

Menu-bar app. Select text anywhere, press a hotkey, a local model streams a rewrite into a floating panel and replaces the selection. Nothing leaves the machine.

macOS 26+, Apple Silicon. `⌃⌥I` = Quick Improve (one prompt, one output). `⌃⌥⇧I` = pick a style, then rewrite. Both configurable; the defaults avoid `⌘I`, which is Italic in most editors.

---

## 0. Iron Law: this codebase is test-driven

**No production code without a failing test first.** Every agent, every change, no exceptions.

```
RED → write one failing test   VERIFY → run it, watch it fail for the right reason
GREEN → least code to pass     VERIFY → run it, watch it pass, nothing else broke
REFACTOR → stay green
```

Wrote code before the test? **Delete it and start over.** Not "keep as reference", not "adapt it". Code nobody watched fail is code nobody knows the test can catch.

**Reports must paste real RED and GREEN output.** Claimed passes with no observed failure are rejected.

Rationalizations already used on this project, all rejected: "already manually tested", "tests after achieve the same goal", "too simple to test", "deleting hours is wasteful", "spirit not ritual".

**Mutation checks run against a copy, never the shared tree.** Breaking code to prove a test catches it is right, and for guards with no honest failing ordering it is the only way. But in a shared checkout it is invisible to you: your runs bracket the mutation, so you see green both sides while anyone building in that window gets a broken artefact and reports failures you cannot reproduce.

**Mutation recovers the evidence, not the design benefit.** A test proved only by breaking the code afterwards has demonstrated it has teeth, which is what RED is *for*, so that evidence stands. But test-first also lets the test shape the API before the code exists, and nothing recovers that later. The tell is writing more than the test demanded, which is only possible when the code leads. Disclose it, prove it by mutation on a copy, and do not make it the habit.

**A green suite does not prove the adapter exists.** `SystemProbing` had a fake, full coverage of every decision behind it, and no production conformance at all — so the app could not be constructed while 63 tests passed. A missing adapter is neither a failing test nor a manual check, so it falls through both lists. **Every seam protocol gets a row in its directory's `AGENTS.md` naming its one production type**, and adding a seam means adding the row.

**Honest exception:** some things can't be unit-tested (Accessibility against a live app, a real multi-GB download, Metal inference). Test at the nearest seam you control and say plainly what stays manual. Never write a test that asserts nothing to claim coverage.

*This project was rebuilt from scratch once because 20 files were written implementation-first.*

## 1. YAGNI

**Build what a test demands. Nothing else.**

**Code** — no abstraction with one implementation, no config for a constant, no scaffolding "for later". No parameter, field, case or overload no behaviour drives: if you can't name the test, don't write it. **Nothing unreferenced** — a symbol with no caller outside its own tests is dead, and tests are not a customer. Delete, don't comment out; git has it.

**Tests** — TDD over-produces these if you let it. One test per *behaviour*, not per implementation detail, so refactoring doesn't break passing tests. **If two tests fail for the same root cause, one is redundant** — it adds no signal and makes one regression look like five. Don't test the stdlib or a plain getter. A test that cannot fail must be deleted or fixed; prove it by breaking the code. Never add a test "for coverage". **An assertion that something did *not* happen needs a positive control in the same test** — `spy.send(k) == false` passes identically when the spy was torn down and nothing ran at all, so pair it with a send that must return true or a side effect that must have fired. **And a test whose input is the thing that might change is not a regression test for that change** — every fake standing in for a measured platform value (Chrome's `AXNumberOfCharacters`, macOS's focus behaviour) supplies the very number whose drift it appears to guard. **A second mechanism preventing the same failure also prevents the first from being observable** — three unpinned guards here sat behind a redundant one, and deleting the spare is what made an honest RED available. **And a fixture that *reaches* a guard is not one that *exercises* it** — the only test touching the rung-8 secure-field check built the exact path to it and revealed an ordinary text field, so deleting the guard broke nothing.

**Docs too** (§2). Every sweep asks: what here does nothing?

## 2. Docs: two files per directory, kept small

`AGENTS.md` holds decisions and **why** (canonical). `CLAUDE.md` is exactly one line, `@AGENTS.md`, never anything else.

**Budget: this file ≤150 lines, per-directory ≤60 — except `AppCore` at ≤90**, which absorbs every branch in the app by design (§4), so it carries four modules' worth of decisions rather than its own. **≤92, and do not compress it further** — merging is where a *why* quietly goes missing. The real answer is splitting `AppCore/Settings/` out, since the transaction engine and the screens share no types and no reasoning, but that is **nine files plus a `Package.swift` `exclude:` change**, so it belongs in a quiet tree as the only thing in flight — never alongside a feature. Over means cut, not append — a 500-line doc protects nothing because nobody reads it, so the guards get buried and removed anyway. That is the only exception and it is named here; declaring yourself the second one is how the rule dies.

**A rule added here must demand an artefact** — a reason per deleted line, a positive control, a `file:line`, an exit status, a test count. Every clause that caught something on this project asks you to produce one; the ones that ask you to be careful caught nobody, and §8's first wording was read by both people who then broke it. An artefact is checkable by a reader, not only by its author. Rationale, not inventory: "snapshots all types" is useless; "a fixed-delay restore races the user and eats what they copied, so restore is gated on `changeCount`" is the point. Skip anything readable from the code in ten seconds. Update a directory's `AGENTS.md` in the same change that alters its decisions; create both files in any new source directory.

## 3. What can actually be replaced

"Anywhere" is true for *reading* a selection, not for *writing* one. Show this in onboarding: a tool that silently does nothing in Ghostty is worse than one that says up front it will hand you the clipboard.

| Context | Capture | Replace |
|---|---|---|
| Native text fields and editors | yes | in place |
| Browser textarea / `contenteditable` | usually | in place |
| VS Code, Cursor, Sublime, Xcode | usually | in place |
| Slack, Discord, Mail, Messages | usually | in place |
| Terminal, Ghostty, iTerm | usually | **copy only** — no editable buffer |
| PDF, ordinary web prose | usually | **copy only** — no editable buffer |
| Password / secure field | **never** | refused before reading |

## 4. Layout

```
EverestKit/            SwiftPM. Everything testable. Every target has a test target.
  RewriteCore/         pure: prompts, validation, presets, catalog, settings
  TextBridge/          read the selection, write it back (AppKit + AX)
  Engines/             MLX + Apple adapters, model download
  Overlay/             the floating panel
Everest/               thin .app shell: App/, Settings/, Resources/
project.yml            xcodegen spec, at repo root
```

Logic in the app target is untestable, and `swift test` does not even *compile* it — only `xcodebuild` does, so an agent editing there is writing blind until someone runs an app build. **A break here is loud to nobody** — omitting a default so the shell "fails loudly" buys nothing on its own, because nothing compiles it; what carries the signal is telling the lead in the same message. Keep the shell thin.

## 5. Model: `mlx-community/Qwen3-4B-Instruct-2507-4bit`

Reverted to a Qwen3.5 model twice by people reading download counts. Do not be the third.

| | Verdict |
|---|---|
| **Qwen3-4B-Instruct-2507** (~2.3 GB) | **Default.** Text-only, non-thinking *by design* (2507 split Instruct/Thinking into separate models), `mlx_lm`, Apache 2.0, ~2s/paragraph. |
| **Qwen3-30B-A3B-Instruct-2507** (~17.2 GB) | Quality option. MoE, ~3B active so ~5s/paragraph. Needs 18-20 GB resident. |
| Apple Foundation Models | Zero-download option, **not default**: guardrails kill streams mid-sentence on ordinary text and can't be disabled. |
| **Any Qwen3.5** | **Disqualified.** Vision-language, thinking on by default, loads via `mlx_vlm`. ~10x slower. `LLMRegistry` ships `qwen3_5_2b_4bit` / `qwen3_6_27b_4bit`, so a substitution **compiles and produces plausible output** — the only symptom is "the app got slow". |

Never bundle a model in the .app; download to `~/Library/Application Support/Everest/Models/`. Pin an exact revision, never a branch.

## 6. Guards that must not be simplified away

Each caused a real defect. Each has a test.

| Guard | Without it |
|---|---|
| Secure-field refusal (subrole `AXSecureTextField`, **not** role) | A password is read into an LLM prompt. Web/Electron fields don't set the global secure-input flag. |
| Prompt-injection frame, not user-editable | Selected text saying "ignore previous instructions" changes app behaviour. |
| Output validation before replacement | The user's email becomes "Sure! Here's an improved version:". |
| Pasteboard restore gated on `changeCount`, and **no suspension point inside a borrow** | Anything copied during a rewrite is destroyed. The process-wide exclusion holds only because every acquire/release pair sits in one synchronous main-actor body — nothing enforces that, and `hold(until:)` made the hitch someone would `await` away bigger. Read `PasteboardBorrow`'s comment before making `apply` async. |
| Oversize clipboard → refuse before writing | "We dropped everything" read as "it was empty" clears the clipboard. |
| Target revalidation before writing | 3s is long enough to click elsewhere. Wrong-target writes are unrecoverable. |
| Range-derived capture → copy-only | A shifted range validates against itself; revalidation can't catch it. |
| Never trim captured text | Silently alters what the user selected. |
| Picker keys consumed by a `CGEventTap`, armed and torn down from `state.didSet` | A digit typed at the picker lands in the document about to be rewritten. Discipline instead of structure leaks a monitor or tap that then watches every keystroke forever. |
| Only the current transaction's original in memory | More is an undeclared history of private selections. |
| No content in logs | Defeats the local-only premise. |

## 7. Platform facts

- **Sandbox is off and the Mac App Store is impossible.** Sandboxed, `AXUIElementSetAttributeValue` and `AXUIElementCopyElementAtPosition` don't work even with permission granted, and `AXIsProcessTrusted()` is permanently false. Never add `com.apple.security.app-sandbox`.
- **A non-activating panel is never key and receives no key events.** Escape needs an `NSEvent` monitor. "Fixing" it to a normal `NSWindow` destroys the selection.
- **A global monitor observes keys; only a `CGEventTap` consumes them.** The picker arms one, measured: without it `3` picks style 3 *and* types `3` into the frontmost app, destroying the selection. The tap needs the same signature-keyed permission and returns nil without it, so **still capture the selection before showing the picker** — one revoked grant and the old behaviour is back.
- **`RewriteEvent.finished` ≠ transaction finished.** Validation and replacement still follow and can fail.
- **Terminals, PDFs and web prose can't be replaced** — no editable buffer. Copy-only is correct behaviour, not a bug.
- Accessibility permission is keyed to the code signature; re-signing forces a re-grant.

## 8. Build

```bash
cd EverestKit && swift test              # all logic, no app needed
xcodegen generate && open Everest.xcodeproj
```

- **Metal Toolchain is a separate download on Xcode 26+**: `xcodebuild -downloadComponent MetalToolchain`. MLX compiles ~40 `.metal` kernels, so without it the build dies before type-checking with `cannot execute tool 'metal'`. Misleading: `xcrun -f metal` still resolves.
- **`swift test` builds *every* test target**, so one agent mid-RED breaks it for all. Isolate: `swift build --target XTests && xcrun xctest .build/out/Products/Debug/XTests.xctest`. `--skip-build` does not work. Same class: **edit `Package.swift` in one write** — adding a product and its target in two writes leaves a window where the graph is invalid (`target 'X' referenced in product 'X' could not be found`), and to anyone else building it reads as their own bug.
- **Always issue build and test as one `&&` command:** `swift build --target XTests && xcrun xctest .build/out/Products/Debug/XTests.xctest`. Two failures present identically here — a confident result the owner cannot reproduce — and they have different causes, so only the single command fixes both. **(1) Stale bundle:** `xcrun xctest` does not rebuild, so a build error you skimmed past runs the *previous* code. **(2) The tree moved:** with several agents writing, a build and a run issued as separate commands are measuring two different trees, and the window is seconds. **(3) A pipe in front of the `&&`:** `swift build … | grep error && xcrun xctest …` hands `&&` *grep's* exit status, not the build's — grep matching the word "error" **succeeds**, so the tests run against the previous bundle. A `;` instead of `&&` is worse, because the tests always run. **Gate on the exit status, never on matched text** — the author of this bullet then gated on `grep -E "error|ok \(build"`, matched the word "error", and reported a stale green. Redirect and grep afterwards: `swift build --build-tests > /tmp/b.log 2>&1; rc=$?`. **(4) A filter that matches nothing:** `xcrun xctest -XCTest '<suite>'` matches no swift-testing suite and prints `Executed 0 tests … passed` — the word "passed" with no test behind it. Run the whole bundle; never filter. Between them these produced four wrong conclusions on this project, including a lead accusing an agent of falsely reporting green, and a lead twice reporting bugs that were already fixed.
- Don't `swift package clean` — it discards the cached ~5 min Metal compile. A mutation copy (§0) needs `.build/workspace-state.json` as well as `checkouts` and `repositories`, or resolution tries to update `mlx-swift`'s submodules and fails without network; with it, the copy builds offline in seconds.
- A local package's `path:` in `project.yml` resolves relative to **the spec file**, not cwd.
- An app target needs an explicit `info:` block or you get `Build input file cannot be found: Info.plist`.
- Re-run `xcodegen generate` after any file rename.
- **The app build needs `-skipPackagePluginValidation`** or it dies on `Validate plug-in "CudaBuild" in package "mlx-swift"` — a clean clone cannot build without it. Ignore the `DVTCoreDeviceCore` plug-in error and `CoreSimulator is out of date` warnings: iOS simulator only, harmless here. Compiling from an agent sandbox needs `dangerouslyDisableSandbox: true`.

## 9. Bundle id, entitlements, dependencies

Bundle id `com.kabrapratik.Everest`. Never hardcode it as an `OSLog` subsystem — use `Bundle.main.bundleIdentifier ?? "Everest"`. A drifting literal fails invisibly: the app runs and `log stream` just returns nothing.

`com.apple.security.cs.allow-jit` is required. Hardened Runtime is on and MLX JIT-compiles Metal shaders, so without it the app builds, launches, then crashes on first model load — looking like an MLX bug.

| Dependency | Why |
|---|---|
| `KeyboardShortcuts` | User-recordable global hotkeys + recorder UI in ~15 lines. Wraps Carbon, so no Input Monitoring permission. |
| `mlx-swift-lm` (pinned `3.31.4`) | Local inference. Pinned, not `main`: 2.x→3.x removed the downloader and tokenizer and broke every call site. |
| `swift-huggingface`, `swift-transformers` | Required by mlx-swift-lm 3.x, which dropped its own. |
| Apple `FoundationModels` | System framework, availability-gated at runtime. |

Don't add a dependency for what a few lines of stdlib cover.
