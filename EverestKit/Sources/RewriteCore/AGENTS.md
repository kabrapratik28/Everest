# RewriteCore: Decisions and Rationale

Canonical instructions for this directory. Read the root `AGENTS.md` first. Written 2026-09-14, Task 1 of the MVP plan.

## What this package is

The non-UI, non-OS-integration brain of the app: prompt building, output validation, presets, the model catalog, and persisted settings. `Engines` implements `RewriteEngine`, `Overlay` renders `RewriteEvent`s, `TextBridge` hands this package raw text and gets validated text back — a rule about prompts, validation, presets, or models changes here first and every consumer sees the same fix.

## Zero dependencies, stays pure

Tests run in ~1s: no Accessibility, no window server, no model download. `import Combine` in `Settings.swift` is not a violation of that — `ObservableObject`/`@Published` impose no GUI requirement. `AppKit`/`SwiftUI` would; never import either here.

## Why `RewriteEvent` uses cumulative snapshots, not deltas

Apple's streaming API yields a full partial response at every step, not a delta. The overlay updates many times a second; a dropped snapshot update just renders a later, still-correct string, where a dropped delta permanently loses a chunk of text. `MLXEngine`, which does get real token deltas, accumulates them into a running string before emitting.

## The prompt-injection guard, and what it does not do

`PromptBuilder.safetyFrame` is fixed and unreachable from Settings; `Preset.instruction` is the only user-editable string. `build` always orders frame, instruction, then the selected text. Never let `instruction` precede `safetyFrame`, or merge the two into one editable string.

**What the delimiter defends against.** The selection is arbitrary text from any app on the machine — a web page, a received message, a shared document, something the user was talked into copying — so it can contain anything, *including the delimiter itself*. A fixed `</selected_text>` was escapable exactly that way: the data block closed early and the rest of the selection read as top-level instructions. The delimiter now carries a fresh 64-bit random id per prompt, in the tag name. Text that cannot name the closing tag cannot close it.

Unpredictable rather than escaped, because escaping is not available here — the selection must reach the model byte for byte. The fixed delimiter did not only admit attacks: it silently split the prompt for anyone honestly writing *about* the tags, which is why the legitimate-text test failed in RED alongside the attack one. Never freeze the id, derive it from the text (the attacker wrote the text), seed it from a counter or the clock, or move it into an attribute — `</selected_text>` is the grammatically correct close for `<selected_text id="…">`, so a forged close would look real.

**What it does not do, which is the part that gets overstated.** A delimiter is not a security boundary. It tells a model which bytes are data; it cannot make the model obey, and semantic resistance stays probabilistic — 4B-class models are weak at it. What bounds the damage is the architecture, not the frame: the model is local, with no tools and no network, so a hijacked generation cannot exfiltrate anything. It can still be steered into producing unrelated content, and Everest writes that into the user's document. `OutputValidator` is the independent second layer and is deliberately shallow: it refuses blank output and nothing else.

Containment stays structural, not detection. If a test here fails, restore the structure; don't add a scanner.

## `OutputValidator`: what it refuses, and what it must not touch

**The 3× ceiling was removed because a structural bound replaced it, not because runaway output stopped mattering — do not put a scanner back.** Output is hard-bounded by `EngineLimits.outputBudget` at `contextCap - inputTokens`, and a generation reaching that bound is refused by `MLXEngine` as `GenerationError.truncated`: a runaway generation *is* a budget-exhausted generation, caught exactly at the decoder instead of guessed from a length afterwards. What the ceiling still caught was a hijack stopping cleanly at a few times the source — the same band the built-in `Expand` style lives in, since expanding a short sentence honestly runs 5–15×. Same lengths, same multiples, no threshold between them, because the difference is intent and the only thing carrying intent is `preset.instruction`, which the user edits. Accepted cost: a hijacked rewrite now replaces the selection rather than being refused — visible, and ⌘Z undoes it, unlike the silent unrecoverable writes this project spends its budget avoiding. What remains is **blank, not merely empty**: `"   \n\t "` passed the old zero-length check and was written over the selection, deleting it silently. Refused in `validate` rather than trimmed in `clean`, because trimming everything that passes would quietly edit rewrites that legitimately end in a newline.

**`clean` has one rule left, and it is the only one that was ever provable.** Three others were deleted, each after it was found deleting somebody's writing. It stripped a hardcoded conversational preamble, so selecting that exact sentence removed it — and it only ever matched that one literal out of everything a model might say. It stripped **any** outer pair of double quotes, which `safetyFrame` expressly asks the model to *preserve*, so a quoted passage came back unquoted and a rewrite merely opening and closing on a quotation mark came back *unbalanced*: `"Hello," he said, … "Goodbye."` → `Hello," he said, … "Goodbye.`. Neither could be saved by the source comparison that saved the envelope: no source tells `"…"` the model added from `"…"` the rewrite legitimately begins and ends with. **Do not add either back** — an unwanted preface or quote pair is visible and undoable; a deleted sentence is neither. What survives is the envelope, because the per-prompt id makes it provable rather than guessed: unwrapped only when an opening tag carrying **exactly the sixteen hex digits `identifier()` pads to** appears once, a closing tag with **that same id** appears once after it, **and the id is not already in the source**. Each clause is a bug that shipped: `[0-9a-fA-F]+` matched `<selected_text_1>`; two separate patterns matched a mismatched pair; a single greedy match **spanned two envelopes** and spliced the original, the commentary and the rewrite together; and shape alone is not ownership, since the cleaner takes any well-formed id — "the user's text contains one" is ordinary for anyone writing about this app, and auto-replace writes the result without asking. Our id is drawn fresh per prompt, so a selection made beforehand cannot hold it unless the user typed it. **Do not write any of this up as "by construction" again — that claim is what kept three people from reading the pattern under it.** Unwrapping strips **one** newline each side, the two `PromptBuilder` adds, never all whitespace: trimming took the indentation off echoed code, root §6's rule one function along. And: **a tidy-up that damages correct input is a worse bug than the tic it was tidying.**

## The model catalog, and why it must never point at Qwen3.5

`ModelCatalog.all` is the fixed list of models this app will ever run. Default is `.qwen4B`; `ModelSpec.isDefault` must stay true only there — it's been changed by mistake twice already by someone reading download counts instead of model behavior.

Any Qwen3.5 model is disqualified: it's a vision-language model (loads via `mlx_vlm`, not the `mlx_lm` path `MLXEngine` is written against), thinking-on-by-default with no working `/nothink`, and none of this fails loudly — it downloads and runs, just ~10x slower with hidden reasoning tokens `OutputValidator` doesn't strip. A silent regression is worse than a crash, which is why this is stated this strongly here and in root `AGENTS.md`.

`ModelSpec.revision` pins an exact commit SHA per root `AGENTS.md` §4 — never a branch, so the weights tested against are the weights a later run actually downloads. `.apple` has no repo, so it carries a fixed sentinel string instead of a real revision: still non-empty, satisfying the shared invariant without implying a pin that doesn't exist.

## Smaller decisions worth knowing about

**Built-in presets use fixed, hand-written UUIDs**, not `UUID()` — a fresh one on every access would break Codable round-tripping through `AppSettings` and SwiftUI list identity, and it is what lets a user's edit of a style survive a version bump. `quickImprove` keeps its own UUID because it is a separately editable field, and it no longer duplicates a picker style: it shipped the picker's "Improve" instruction verbatim, so the hotkey and the first row did the same thing and one of the choices bought nothing. Proofread — corrections only, no stylistic rewriting — holds that UUID now. **The instruction strings are not pinned by a test and should not be**: they are prompt wording, tuned against the model, and a test asserting the data equals itself fails on every honest improvement. The properties with tests are the ids, the order, and that Quick Improve is not a style in disguise.

**`AppSettings` is `UserDefaults`-backed with an injectable store** (`init(store: UserDefaults = .standard)`), so a test or preview never touches the real user's defaults. `.shared` still works exactly as the plan specifies.

**Every public struct has an explicit `public init`.** Swift's synthesized memberwise init defaults to internal access even on a public struct — it compiles here and is still unconstructable from another module. A prior attempt let `ModelSpec` skip this and construction from `Engines` failed silently.

**`RewriteRequest`, `RewriteEvent`, `EngineAvailability`, and `RewriteEngine`** (`RewriteEngine.swift`) have no driving test. They pass YAGNI — `Engines`, `Overlay`, and `TextBridge` are three real consumers that need them to compile — and need no test under the Iron Law, since pure shape with no branching logic has no failure mode a test could catch. The moment any of them grows real behavior, that behavior gets a test first.

**`AppSettings` is `@MainActor`; tests touching it must be too**, or Swift 6 strict concurrency rejects the call.

## Running the tests

From `EverestKit`: `swift build --target RewriteCoreTests && xcrun xctest .build/out/Products/Debug/RewriteCoreTests.xctest`. Not plain `swift test`, which builds every target in the package, so another agent mid-RED breaks your runner and it reads as your bug.

Three test files, and a count here would only go stale. **`PromptBuilderTests.swift` is the adversarial one** — a selection that forges the closing delimiter, a fresh id per build, and the legitimate case that must not be censored. Extend it rather than starting a second, weaker file: the escape above survived behind a test whose payload contained no delimiter, so it passed against vulnerable code and stopped anyone looking again. `CoreTests.swift` holds `OutputValidator`, `Preset` and `ModelCatalog`; `AppSettings` has its own. Give new behavior its own test file.
