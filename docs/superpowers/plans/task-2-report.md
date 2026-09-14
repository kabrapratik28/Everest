# Task 2 report: Selection and replacement

Written 2026-09-14, revised after the Everest rename. Scope: `Improve/Selection/` and `Improve/Replacement/` only (directory names unchanged by instruction). Nothing outside those two directories was touched.

## Status

Complete. All seven source files plus four documentation files are written. The code compiles clean and, contrary to the stated build constraint, it was possible to verify most of it running against real applications.

## Files created

Source:

- `/Users/kabara/Desktop/Improve/Improve/Selection/TargetSnapshot.swift`
- `/Users/kabara/Desktop/Improve/Improve/Selection/AXSelectionAdapter.swift`
- `/Users/kabara/Desktop/Improve/Improve/Selection/ClipboardSelectionAdapter.swift`
- `/Users/kabara/Desktop/Improve/Improve/Selection/SelectionCoordinator.swift`
- `/Users/kabara/Desktop/Improve/Improve/Replacement/PasteboardTransaction.swift`
- `/Users/kabara/Desktop/Improve/Improve/Replacement/TargetValidator.swift`
- `/Users/kabara/Desktop/Improve/Improve/Replacement/ReplacementService.swift`

Documentation:

- `/Users/kabara/Desktop/Improve/Improve/Selection/AGENTS.md` and `CLAUDE.md`
- `/Users/kabara/Desktop/Improve/Improve/Replacement/AGENTS.md` and `CLAUDE.md`

## Public surface, as the plan specifies

```swift
@MainActor final class SelectionCoordinator {
    var excludedBundleIDs: [String]
    init(excludedBundleIDs: [String], clipboard: ClipboardSelectionAdapter = ClipboardSelectionAdapter())
    func capture() throws -> TargetSnapshot
}

@MainActor enum ReplacementService {
    static func apply(_ text: String, to snapshot: TargetSnapshot) -> ReplaceOutcome
}
```

`TargetSnapshot`, `CaptureError` and `ReplaceOutcome` are declared verbatim from the plan, all three in `Selection/TargetSnapshot.swift` where the plan puts them. Nothing was added to or removed from those declarations. `CaptureError` gained a `userMessage` property in a separate extension so the overlay does not have to invent wording.

Two notes for Task 5:

- `excludedBundleIDs` is a settable property, not just a constructor argument. Assign to it when the user edits the exclusion list in Settings, otherwise the coordinator's copy goes stale.
- `ReplacementService.apply` is static because it has nothing to configure. `SelectionCoordinator` is an instance because it carries the exclusion list and the strategy cache.

## What I verified

The Xcode license was already accepted, so the constraint in the brief did not apply. There is still no Xcode project, so nothing was built as an app target, but the seven files form a self-contained module with no RewriteCore dependency and could be compiled and executed directly.

**Compilation.** `xcrun swiftc -typecheck` and a full optimised `-wmo -O` object compile, both with `-swift-version 6 -strict-concurrency=complete`, targeting `arm64-apple-macosx26.0`. Zero errors, zero warnings.

**Pasteboard transaction, 28 checks against a private `NSPasteboard`.** Multi-item multi-type round trip with byte-exact data and preserved type order, including RTF and PNG flavours alongside plain text. Restore declining when something else writes mid-transaction, with the other content left intact. Empty clipboard round trip. `abandon` leaving our text in place. Transient and auto-generated markers present on our write and absent after restore. Durable writes carrying no markers. Awkward text (leading and trailing whitespace, tabs, CRLF, zero-width space, combining accent, a family emoji) restored byte for byte.

**End to end against TextEdit, 33 checks.** Capture of the exact selection, correct pid, bundle identifier, app version, range, role and editability. Validator agreeing when nothing changed. A stale snapshot refused with the document untouched and the rewrite placed on the clipboard. The user moving the selection between capture and apply also refused. The accessibility write route actually replacing text in the document. Whitespace preserved byte for byte through capture. Zero-length range giving `.noSelection`. Exclusion list refusing a perfectly good selection. Synthetic Command C reading the selection and the user's clipboard restored afterwards. A synthetic copy with nothing selected returning nil rather than the stale clipboard, with the clipboard untouched. The paste route composed exactly as `pasteReplace` composes it: transient write, synthetic Command V, consumption observed, document showing the paste, user's clipboard restored.

**Secure field refusal, against a real bundled app with an `NSSecureTextField`.** A plain `NSTextField` in the same app captured normally, so the refusal is specific rather than a blanket failure. The secure field was refused with `.secureField`. Worth recording: a real `NSSecureTextField` reports **role `AXTextField` with subrole `AXSecureTextField`**. A role-only check would have missed it and read the password. `IsSecureEventInputEnabled()` also returned true while that field held focus, so both layers of the guard fire independently.

The user's real clipboard was snapshotted and restored around every harness run, and all test apps were quit. The machine was left as it was found. All harnesses were throwaway and live outside the repository.

## Two real bugs the testing found

**The system-wide focused element is not reliable on its own.** `AXFocusedUIElement` on `AXUIElementCreateSystemWide()` returns `kAXErrorCannotComplete` (-25204) against TextEdit on macOS 26, while the identical query against TextEdit's own application element succeeds immediately. My first version used only the system-wide element and therefore failed to capture anything in an ordinary Apple app. `AXSelectionAdapter.focusedElement(pid:)` now tries system-wide first and falls back to the application element.

That change also closed a hole I had not noticed. The result is now required to belong to the pid we checked. The exclusion list and bundle identifier are evaluated against the frontmost process, so an element owned by a different process would have been text that was never checked against the user's list of apps Everest must stay out of.

**`snapshotIsComplete` was crying wolf.** It was set whenever `data(forType:)` returned nil, which happens routinely for flavours AppKit derives on demand such as `public.utf16-external-plain-text`. Those carry no bytes to lose and are re-advertised automatically once the base types are restored. The flag now means only what it should: real bytes were dropped by the size budget.

## Concerns

**Naming.** The product name is now Everest, and every user-facing string and documentation sentence in my two directories says Everest. Directory paths were deliberately left alone per instruction, so the code still lives under `Improve/Selection/` and `Improve/Replacement/` and my prose refers to those paths as they are on disk. When the central directory rename happens, those path references need sweeping; the product name does not, because it is already done.

The rename was applied with a lookahead that skips any `Improve` followed by a slash, so no path was touched. There were no occurrences of the product name inside an identifier, and no compound words such as "Improvement", so nothing was caught by accident. The three user-facing strings that changed are the `CaptureError.userMessage` sentences and the `.copiedOnly` reason for revoked permission. The `OSLog` subsystem fallback in all five loggers also changed, from `"Improve"` to `"Everest"`; it is only used when `Bundle.main.bundleIdentifier` is nil, which will not happen in the real app target, but it should match the product regardless.

**Two branches are written but not executed.** The `AXManualAccessibility` retry for Chromium and Electron, and the `AXStringForRange` branch. Both need an app that exhibits the relevant gap, and neither was safe to drive on the user's machine without their say-so. They are written from documented and widely reproduced behaviour, and they are flagged as the least proven code in both `AGENTS.md` files. If you want them verified, the cheap test is a Slack or VS Code window with a sentence selected.

**`pasteReplace` itself was exercised by parts, not as a whole.** TextEdit accepts the direct accessibility write, so route two never fires there. Every component of route two was verified individually and composed by hand in the same order, but the function body itself has not run.

**Capture blocks the main thread.** `capture()` is synchronous per the specified signature, so the clipboard fallback's bounded waits block. Worst case is about 500 ms, only on the path that accessibility-hostile apps reach. I chose blocking over pumping the run loop deliberately: pumping from inside a hotkey handler would let a second hotkey press re-enter the chain while the first is halfway through borrowing the clipboard. If Task 5 finds the hitch visible, the fix is to make the fallback async, which changes the signature the plan fixes, so it is a decision for the human rather than for me.

**One unavoidable privacy leak, documented rather than fixed.** On the synthetic-copy path the *target app* writes the selected text to the pasteboard. That write is not ours, so it cannot be marked transient, and a clipboard history app will record it. We restore within a few hundred milliseconds but the exposure is real. It is a reason to keep the accessibility paths healthy rather than letting apps drift onto the clipboard path, and it is recorded in `Selection/AGENTS.md`.

**A deliberate limitation that will look like a bug.** A selection captured through the clipboard path can never be written back automatically and always ends in `.copiedOnly`. There is no route by which to prove where a paste would land in an app we could not read. Someone will report this as a bug. It is not, and both `AGENTS.md` files say so.

---

# Fix report, round 1

Appended after the review at `docs/superpowers/plans/task-2-review.md`. All four required changes are made, plus five of the seven Minor findings. Everything re-verified below.

## What changed

### Critical: an oversize clipboard is no longer destroyed

Fixed at the front, as directed, not at the restore end.

`PasteboardTransaction` now has a three-state `Fidelity` (`notTaken`, `faithful`, `lossy`) in place of the boolean that conflated *the clipboard was empty* with *we could not afford to save it*. `snapshot()` returns `Bool` and is `@discardableResult`-free at both call sites, which now refuse to proceed:

- `ClipboardSelectionAdapter.copySelection` returns nil **before posting Command C**, because that keystroke makes the target app overwrite the clipboard and we could not put it back.
- `ReplacementService.pasteReplace` abandons route two **before `writeTransient`**.

A lossy snapshot also discards the partial copy it did manage to hold, so no caller can mistake it for a usable restore, and `restoreIfUnchanged` refuses outright on a lossy snapshot and leaves the pasteboard untouched. That last one is a backstop for a future caller who forgets the front check, not the mechanism.

One consequence I want on the record rather than buried: `pasteReplace` falls back to `.copiedOnly`, and that outcome overwrites the clipboard by definition. A user with an unsavable clipboard and a route-two app still loses it. The difference from the bug is that it is now a single deliberate overwrite the overlay reports, instead of a silent wipe inside a restore returning `true`. Route one never touches the clipboard, so most apps never reach it. If you want the stronger behaviour, it needs an outcome case the plan does not have, and that is your call rather than mine.

### Important: the secure-field guard can no longer be skipped by the cache

Restructured rather than patched. `capture()` now resolves focus once, up front, escalating with `AXManualAccessibility` when the app answers nothing, and runs `refuseIfSecure` on the result **before the strategy cache is consulted at all**. The resolved element is threaded into both capture paths. `captureViaClipboard` repeats the refusal immediately before the keystroke, and no longer resolves an element after the text is already read. The manual-accessibility retry re-resolves and re-checks, because the element it finds did not exist when the first check ran.

Residual gap, documented rather than papered over: an app that exposes no accessibility tree even after escalation gives nothing to inspect, so only the global flag applies there. That is the irreducible cost of having a clipboard rung at all. The user's mitigation is the exclusion list.

### Important: the `AXStringForRange` rung now fails closed

Took the stronger code fix rather than the documentation-only change the review asked for. `TargetSnapshot` gains one field, `isRangeDerived`, set when text was reconstructed from the range, and `ReplacementService.apply` refuses any such snapshot with `.copiedOnly` **before** calling the validator, so nobody later reads a passing validator as evidence the write is safe.

The field is a `var` with a default while every other field is a `let`, for a mechanical reason worth knowing: a `let` with a default value is excluded from Swift's memberwise initializer, so it would have been permanently false and the guard would have been dead code that looked alive. `var` keeps it settable at construction and leaves the plan's initializer signature source compatible. This is the one addition to the type the plan declares verbatim, and it is noted in the source.

### Important: both `AGENTS.md` files corrected

`Selection/AGENTS.md`: rung 4 is now described accurately, with a new rung 3a for focus resolution; a new paragraph states that the cache is consulted only after rung 4 and that moving it above `refuseIfSecure` reintroduces the bug; the strategy-cache section now spells out exactly which rungs a cached `.clipboard` entry skips (5 to 9) and which it does not (0 to 4); the false sentence about the range never reconstructing text is replaced with a section on rung 7 being the one place the off-by-one is unmitigated, why revalidation is structurally unable to catch it, and how it fails closed.

`Replacement/AGENTS.md`: a new section titled "The blocking is the re-entrancy guard. Do not make this async." spelling out the exact nesting mechanism, that the `changeCount` guard cannot help because under re-entrancy the other writer is us, and what a real fix would require. A new section on the all-dropped budget edge with the reproduction, the three-state reasoning, and why the check cannot work at the back.

### Minor findings also fixed

- **5** `snapshotIsComplete` was dead. Replaced by `fidelity` and `canBorrow`, both read by callers and by tests.
- **7** Route two was gated on the stale `snapshot.isEditable` two lines after a live settability check. Editability is now re-derived live.
- **8** `observeConsumption` now re-checks that the target is still frontmost each poll, so focus loss is no longer reported as a successful paste.
- **9** `expect(changeCount:)` was handed a count read after the text. Replaced with `waitForStableString`, which reads count, text, count again and returns nil unless the two counts agree, turning that race into a clean "we do not know".
- **10** `restoreIfUnchanged` now calls `discard()` on the early return, and `discard()` resets fidelity, so up to 16 MB is not held alive.

**Not fixed: 6 and 11.** An app with no bundle identifier still cannot be excluded or cached, which is correct behaviour; I have left the code alone. 11 was recorded as a scope note, not a defect.

## Commands run, and their output

**1. Per-file parse, the command you asked for.**

```
for f in Improve/Selection/*.swift Improve/Replacement/*.swift; do
  xcrun swiftc -parse -target arm64-apple-macos26.0 "$f"
done
```

All seven `PARSE OK`.

**2. Strict concurrency typecheck and optimised whole-module compile.**

```
xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos26.0 Improve/Selection/*.swift Improve/Replacement/*.swift
xcrun swiftc -c -O -wmo -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos26.0 -module-name Everest Improve/Selection/*.swift Improve/Replacement/*.swift
```

Both exit 0, zero errors, zero warnings.

**3. Offline pasteboard suite, now 40 checks including the Critical regression.** New checks 9a to 12b:

```
PASS  9a snapshot refuses to borrow an unsavable clipboard
PASS  9b fidelity is .lossy
PASS  9c canBorrow is false
PASS  9d restore refuses rather than clearing
PASS  9e pasteboard untouched: item still there
PASS  9f pasteboard untouched: all 40 MB still there
PASS  9g change count never moved
PASS  10a copySelection declines
PASS  10b clipboard still intact after decline
PASS  10c no pasteboard write occurred
PASS  11a affordable clipboard is borrowable
PASS  11b restore succeeds
PASS  11c 1 MB payload restored byte for byte
PASS  12a default is false
PASS  12b can be set
ALL PASS
```

Same 40 MB TIFF as your repro. Where the old code returned `true` with an empty pasteboard, it now returns `false` with all 41,943,040 bytes still present and the change count never moved. Check 11 exists so the guard cannot pass by simply disabling the feature.

**4. Cached-clipboard secure bypass, the decisive test.** A purpose-built signed app with two focusable things: a view that is opaque to accessibility but implements `copy:` (with a real Edit menu, since Command C only reaches `copy:` through a menu key equivalent), and a plain `NSTextField` carrying `setAccessibilitySubrole("AXSecureTextField")`. That second one is the point: it looks exactly like a web password input over accessibility and does **not** set secure event input. One `SelectionCoordinator` instance across all three phases, so the cache persists.

```
      phase1 focused role=AXWindow selText="nil"
PASS  1a captured via the clipboard fallback   ["opaque selection text"]
PASS  1b no range, as the clipboard path cannot report one
PASS  1c user clipboard restored after the copy   ["USER CLIPBOARD"]
PASS  1d clipboard-derived capture refuses to write   [copiedOnly(reason: "The selection could not be confirmed")]
PASS  2a global secure-input flag is NOT what protects us here   [IsSecureEventInputEnabled()=false]
      phase2 focused role=AXTextField subrole=AXSecureTextField
PASS  2b field reports the secure subrole
      (text the field would have leaked: "hunter2")
PASS  2c cached-clipboard app STILL refuses a secure field   [secureField]
PASS  2d no synthetic copy was posted at the secure field
PASS  2e clipboard untouched
PASS  3a opaque view captures again   ["opaque selection text"]
ALL PASS
```

Phase 1 proves the cache entry is genuinely `.clipboard`: the text returned can only have come from the synthetic copy, since accessibility reported `AXWindow` with no selected text. Phase 2 then proves the refusal with the global flag measured as false, so the subrole check is demonstrably the only thing that refused. Phase 3 proves the app still works afterwards, so the refusal is about the field and not a poisoned cache.

**5. Full TextEdit end-to-end suite re-run after the refactor.** All 33 checks still pass, unchanged. The focus hoisting, element threading, live editability and new frontmost check introduced no regressions.

**6. Greps.** No `trimming`, no normalisation. No `asyncAfter`, `Timer`, `DispatchQueue` or `async` anywhere in either directory, so the blocking design that the re-entrancy argument depends on is intact. Both `snapshot()` call sites are `guard`ed.

## Still not verified live

Unchanged from the first report, and worth repeating because the review asked about them. The Electron and Chromium `AXManualAccessibility` branch, and the `AXStringForRange` branch, still have no live coverage; neither was safe to drive on the user's machine. Rung 7 now fails closed regardless, so an untested branch cannot produce a write. `pasteReplace` is still exercised by composing its parts rather than by executing the function, since TextEdit accepts the route-one write.
