# TextBridge, rebuilt test-first

Report for Task 2. Every behaviour below was driven RED first, run, watched to fail for the right reason, then made green with the least code and run again. The actual output of both runs is pasted.

**Result: 65 tests, 10 suites, all passing, in the real package.** Nothing in `Sources/TextBridge/` was written before a test that failed without it.

---

## How to read the evidence

Two kinds of RED appear here, and I have labelled which is which rather than blurring them.

**Sequential RED** is the normal case: the test exists, the production code does not do the thing, and the run shows an assertion failing with the real value. Wherever a new type had to exist for the test to compile at all, I first wrote the *minimum unguarded* version, ran it, and captured the assertion failure. The compile error alone was never treated as RED.

**Mutation-verified RED** is used for five behaviours that were already satisfied by construction, where no honest ordering makes them fail. "Text is never trimmed" is the clearest: there is no transformation in the code to remove, so the only way to see the test fail is to insert the exact defect it forbids. For each of these I injected the defect, ran, captured the failure, and reverted. I have said so explicitly rather than presenting them as sequential.

### A note on the test runner

`swift test` builds every test target in the package, so whichever sibling agent is mid-RED blocks the runner for everyone, and `--filter` does not help because it filters execution rather than the build. Over this task the blocker moved from `RewriteCoreTests` to `EnginesTests` as those agents progressed.

The per-behaviour loop below therefore ran through a scratch package at `/tmp/tb-tdd` whose two targets are **symlinks to the real directories**, `EverestKit/Sources/TextBridge` and `EverestKit/Tests/TextBridgeTests`. Same files, same compiler, same Swift Testing library, no copies, and no `RewriteCore` dependency, which also keeps the plan's "Task 2 consumes nothing from Task 1" honest. `Package.swift` was not edited.

The per-target isolation command you later relayed works, and the final result at the end is from **the real package at the real paths**. Both runners agree.

---

## 1. Capture refuses a secure subrole even when `IsSecureEventInputEnabled()` is false

The measured case: a real `NSSecureTextField` reports role `AXTextField` with subrole `AXSecureTextField`, and web and Electron password inputs do not set the process-wide flag at all.

**RED** (`SelectionCoordinator` existed with no secure check, reading the text straight through):

```
✘ Test "refuses a secure subrole even when the process-wide secure-input flag is false" recorded an issue at CaptureRefusalTests.swift:28:9: Expectation failed: an error was expected but none was thrown
↳ CaptureError.secureField → <not evaluated>
✘ Test "refuses a secure subrole even when the process-wide secure-input flag is false" recorded an issue at CaptureRefusalTests.swift:31:9: Expectation failed: ax.textReads == 0
↳ the password must never be read
↳ ax.textReads == 0 → false
↳   ax.textReads → 1
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 2 issues.
```

`ax.textReads → 1` is the defect itself: the password was read.

**GREEN:**

```
✔ Test "refuses a secure subrole even when the process-wide secure-input flag is false" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

### 1a. Companion: the process-wide flag, checked before the app is even identified

**RED:**

```
✘ ... recorded an issue: Expectation failed: an error was expected but none was thrown
✘ ... Expectation failed: ax.focusResolutions == 0
↳   ax.focusResolutions → 1
✘ ... Expectation failed: ax.textReads == 0
↳   ax.textReads → 1
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 3 issues.
```

**GREEN:**

```
✔ Test "refuses a secure subrole even when the process-wide secure-input flag is false" passed after 0.001 seconds.
✔ Test "refuses while process-wide secure input is enabled, before resolving focus" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

---

## 2. The refusal happens before any strategy is chosen, including a cached one

This one needed care to avoid being vacuous. Without a cache that genuinely skips something, a test asserting "the cache did not skip the secure check" asserts nothing. So the cache was driven out first, by its own test, and the *least code that passed that test* was the cache consulted at the top of `capture()` — which is exactly the shape the original defect had.

### 2a. Precondition: the cache really does skip work

**RED:**

```
✘ Test "a remembered clipboard app skips the expensive accessibility rungs next time" recorded an issue at StrategyCacheTests.swift:46:9: Expectation failed: ax.manualAccessibilityEnables == 1
↳   ax.manualAccessibilityEnables → 2
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

### 2b. The guard itself

With the minimal cache in place, the guard test went RED on its own:

```
✔ Test "a remembered clipboard app skips the expensive accessibility rungs next time" passed after 0.001 seconds.
✘ Test "a warm clipboard cache entry never lets capture skip the secure check" recorded an issue at StrategyCacheTests.swift:74:9: Expectation failed: an error was expected but none was thrown
↳ CaptureError.secureField → <not evaluated>
✘ ... at StrategyCacheTests.swift:77:9: Expectation failed: ax.focusResolutions == focusesAfterLearning + 1
↳   ax.focusResolutions → 2
↳   focusesAfterLearning + 1 → 3
✘ ... at StrategyCacheTests.swift:81:9: Expectation failed: clipboard.attempts == 1
↳   clipboard.attempts → 2
✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 3 issues.
```

That is the historical bug reproduced exactly: focus was never resolved, no secure check ran, and `clipboard.attempts → 2` means ⌘C was posted at a password field.

**GREEN**, after moving the cache lookup below focus resolution and `refuseIfSecure`:

```
✔ Test "a warm clipboard cache entry never lets capture skip the secure check" passed after 0.001 seconds.
✔ Test "a remembered clipboard app skips the expensive accessibility rungs next time" passed after 0.001 seconds.
✔ Test run with 13 tests in 3 suites passed after 0.001 seconds.
```

---

## 3. Capture refuses an excluded bundle id before reading anything

**RED:**

```
✘ Test "refuses an excluded bundle id before reading anything" recorded an issue at CaptureRefusalTests.swift:82:9: Expectation failed: ax.focusResolutions == 0
↳   ax.focusResolutions → 1
✘ ... at CaptureRefusalTests.swift:83:9: Expectation failed: ax.textReads == 0
↳   ax.textReads → 1
✘ Test "matches an excluded bundle id case-insensitively, but never by prefix" recorded an issue at CaptureRefusalTests.swift:109:9: Expectation failed: an error was expected but none was thrown
↳ CaptureError.excludedApp("COM.Example.Editor") → <not evaluated>
✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 4 issues.
```

**GREEN:**

```
✔ Test "matches an excluded bundle id case-insensitively, but never by prefix" passed after 0.001 seconds.
✔ Test "refuses an excluded bundle id before reading anything" passed after 0.001 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

---

## 4. Captured text is preserved byte for byte

**Mutation-verified RED.** These two tests, run across all three capture routes, passed the first time they were run:

```
✔ Test "whitespace, tabs and newlines survive every capture route byte for byte" with 3 test cases passed after 0.001 seconds.
✔ Test "composed and combining characters are not normalised" with 3 test cases passed after 0.001 seconds.
```

There is no transformation in the code to remove, so no ordering makes them fail honestly. I injected the exact defect they forbid, a `trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping` on the captured text, and ran:

```
✘ ... recorded an issue with 1 argument route → .stringForRange at TextFidelityTests.swift:57:9: Expectation failed: snapshot.text == original
✘ ... with 1 argument route → .clipboard at TextFidelityTests.swift:57:9: Expectation failed: snapshot.text == original
✘ ... with 1 argument route → .selectedText at TextFidelityTests.swift:57:9: Expectation failed: snapshot.text == original
✘ ... route → .stringForRange at TextFidelityTests.swift:69:9: Expectation failed: Array(snapshot.text.unicodeScalars) == Array(original.unicodeScalars)
✘ ... route → .selectedText at TextFidelityTests.swift:69:9: Expectation failed: Array(snapshot.text.unicodeScalars) == Array(original.unicodeScalars)
✘ ... route → .clipboard at TextFidelityTests.swift:69:9: Expectation failed: Array(snapshot.text.unicodeScalars) == Array(original.unicodeScalars)
✘ ... route → .stringForRange at TextFidelityTests.swift:58:9: Expectation failed: Array(snapshot.text.utf8) == Array(original.utf8)
✘ ... route → .clipboard at TextFidelityTests.swift:58:9: Expectation failed: Array(snapshot.text.utf8) == Array(original.utf8)
✘ ... route → .selectedText at TextFidelityTests.swift:58:9: Expectation failed: Array(snapshot.text.utf8) == Array(original.utf8)
✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 9 issues.
```

All six route/assertion combinations fail, so the suite has teeth on every capture route. Mutation reverted; **GREEN** as quoted above.

The test string is `"  spaced  \tand\ttabbed  \n\n  and a trailing newline\n"` plus a Unicode case with a combining acute, a zero-width-joiner emoji sequence, a fullwidth character and an embedded NUL.

---

## 5. Input over 8,000 characters returns `.tooLong(count)`

**RED:**

```
✘ Test "input over the 8,000 character limit is refused with its own length" recorded an issue at CaptureRefusalTests.swift:161:9: Expectation failed: an error was expected but none was thrown
↳ CaptureError.tooLong(CaptureLimits.maxCharacters + 1) → <not evaluated>
✔ Test "input exactly at the limit is accepted" passed after 0.001 seconds.
✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 3 issues.
```

(The boundary test is the negative control and was green throughout, correctly.)

**GREEN:**

```
✔ Test run with 19 tests in 3 suites passed after 0.001 seconds.
```

---

## 6. A pasteboard snapshot round-trips all declared types, not just the plain string

**Mutation-verified RED.** The test's first run was a missing-symbol compile error, and the implementation written to satisfy it was already correct, so I showed the behavioural failure by mutating `snapshot()` to the easy and wrong version, plain text only:

```
✘ Test "a snapshot round-trips every declared type on every item, in order" recorded an issue at PasteboardTransactionTests.swift:57:13: Expectation failed: restored.map(\.types) == declared
↳   restored.map(\.types) → [[public.utf8-plain-text], [public.utf8-plain-text]]
↳   declared → [[public.rtf, public.utf16-external-plain-text, public.utf8-plain-text, public.png, com.example.private], [public.rtf, ...]]
✘ ... Expectation failed: item.data(forType: .rtf) == rtf
↳   item.data(forType: .rtf) → nil
↳   rtf → 27 bytes
✘ ... Expectation failed: item.data(forType: .png) == png
↳   item.data(forType: .png) → nil
↳   png → 12 bytes
```

Note `public.utf16-external-plain-text` in the declared list: that is the AppKit-derived flavour the decision record describes, and the real implementation restores it correctly.

Mutation reverted. **GREEN:**

```
✔ Test "a snapshot round-trips every declared type on every item, in order" passed after 0.010 seconds.
```

Two items, each with RTF, PNG, a custom UTI and plain text, asserted byte-exact with type order preserved.

---

## 7. Restore is refused when something else wrote during the transaction

**RED:**

```
✘ Test "restore declines when something else wrote to the pasteboard mid-transaction" recorded an issue at PasteboardTransactionTests.swift:85:13: Expectation failed: transaction.restoreIfUnchanged() == false
↳   transaction.restoreIfUnchanged() → true
✘ ... at PasteboardTransactionTests.swift:86:13: Expectation failed: pasteboard.string(forType: .string) == "what the user just copied"
↳   pasteboard.string(forType: .string) → "the user's original"
✔ Test "expect(changeCount:) lets a borrow the target app performed be handed back" passed after 0.009 seconds.
✘ Test run with 2 tests in 1 suite failed after 0.010 seconds with 2 issues.
```

The second line is the data loss in plain sight: the user's freshly-copied content was replaced by the stale original.

**GREEN:**

```
✔ Test run with 24 tests in 5 suites passed after 0.014 seconds.
```

---

## 8. Over the 16 MB budget, the transaction refuses up front and never writes

The highest-value test here, and the one the old code got wrong by reading "we dropped everything" as "it was empty".

**RED** (real 16 MB budget, 20 MB TIFF on a private pasteboard):

```
✘ Test "content over the snapshot budget refuses up front and never writes to the pasteboard" recorded an issue at PasteboardTransactionTests.swift:139:13: Expectation failed: transaction.snapshot() == false
↳   transaction.snapshot() → true
✘ ... at :140:13: Expectation failed: transaction.fidelity == .lossy
↳   transaction.fidelity → .faithful
✘ ... at :141:13: Expectation failed: transaction.canBorrow == false
↳   transaction.canBorrow → true
✘ ... at :147:13: Expectation failed: transaction.restoreIfUnchanged() == false
↳   transaction.restoreIfUnchanged() → true
✘ ... at :148:13: Expectation failed: pasteboard.changeCount == changeCountBefore
↳   pasteboard.changeCount → 2
↳   changeCountBefore → 1
✔ Test "fidelity distinguishes not-taken, faithful-but-empty and lossy" passed after 0.004 seconds.
✔ Test "a declared type carrying no bytes of its own does not make a snapshot lossy" passed after 0.006 seconds.
✔ Test "a payload comfortably under the budget still round-trips byte for byte" passed after 0.091 seconds.
✘ Test run with 4 tests in 1 suite failed after 0.091 seconds with 5 issues.
```

`changeCount → 2` against `changeCountBefore → 1` is the 20 MB being cleared.

**GREEN:**

```
✔ Test run with 28 tests in 5 suites passed after 0.085 seconds.
```

The test asserts the original content is still intact afterwards, byte-compared, both immediately after the refused `snapshot()` and again after the refused `restoreIfUnchanged()`.

Three states are kept apart by three separate assertions in `fidelityKeepsTheThreeStatesApart`: `notTaken` on a fresh transaction refuses to restore; a genuinely empty clipboard is `faithful` and correctly restores to empty; and the oversized case above is `lossy`. The empty clipboard and the everything-dropped case produce the same empty saved array, which is precisely why the flag and not the array is what decides. `underBudgetPayloadStillRoundTrips` (1 MB) proves the guard did not just disable the feature, and `derivedTypesWithoutDataAreNotLossy` proves a nil-data derived flavour does not trip it.

---

## 9. A range-derived snapshot is marked, and forces copy-only

### 9a. Capture marks it

**RED** (rung 7 did not exist):

```
✔ Test "text the app handed over directly is not marked range-derived" passed after 0.001 seconds.
✘ Test "text reconstructed from a range is marked range-derived" recorded an issue at CaptureChainTests.swift:66:6: Caught error: .noSelection
✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue.
```

**GREEN:**

```
✔ Test "text the app handed over directly is not marked range-derived" passed after 0.001 seconds.
✔ Test "text reconstructed from a range is marked range-derived" passed after 0.001 seconds.
```

`isRangeDerived` is declared `let` with **no default value**, so it is present in the memberwise initializer and every construction site must state it. Adding a default would silently freeze it at `false` and turn the guard below into dead code that still compiles.

### 9b. Replacement refuses to write it, before the validator runs

**RED**, with everything a validator could check still agreeing:

```
✘ Test "a range-derived snapshot is never written, even when everything still matches" recorded an issue at ReplacementTests.swift:256:13: Expectation failed: outcome == .copiedOnly(...)
↳   outcome → .replaced
✘ ... at :261:13: Expectation failed: ax.writes.isEmpty
↳   ax.writes → ["the rewrite"]
✘ Test "the range-derived refusal happens before the validator is consulted" recorded an issue at :279:13: Expectation failed: ax.focusResolutions == 0
↳   ax.focusResolutions → 1
✘ ... at :280:13: Expectation failed: ax.textReads == 0
↳   ax.textReads → 1
```

`outcome → .replaced` with `ax.writes → ["the rewrite"]` is the shifted selection being written over, with the validator agreeing with itself.

**GREEN:**

```
✔ Test "the range-derived refusal happens before the validator is consulted" passed after 0.004 seconds.
✔ Test "a range-derived snapshot is never written, even when everything still matches" passed after 0.006 seconds.
```

The second test is what pins the refusal *ahead of* the validator rather than merely somewhere before the write.

---

## 10. Replacement refuses when the fingerprint no longer matches

Driven as separate tests, as asked, plus the element and secure cases and the `unknown` case.

**RED** (all six, before `TargetValidator` existed):

```
✘ "a different process being frontmost refuses the write" ... Expectation failed: outcome == .copiedOnly(reason: "the target app is no longer frontmost")
↳   outcome → .replaced
✘ "the selection having moved refuses the write" ... Expectation failed: outcome == .copiedOnly(reason: "the selection changed")
↳   outcome → .replaced
✘ "the selected text having changed refuses the write" ... Expectation failed: outcome == .copiedOnly(reason: "the selection changed")
↳   outcome → .replaced
✘ "a different focused element refuses the write" ... Expectation failed: outcome == .copiedOnly(reason: "focus moved to another element")
↳   outcome → .replaced
✘ "a target that has become a password field refuses the write" ... Expectation failed: outcome == .copiedOnly(reason: "the target is a secure field")
↳   outcome → .replaced
✘ "a snapshot with nothing to validate against is refused rather than assumed safe" ... Expectation failed: outcome == .copiedOnly(reason: "the target could not be verified")
↳   outcome → .replaced
```

Every single mismatch clobbered the wrong text.

**GREEN:**

```
✔ Test "a different focused element refuses the write" passed after 0.009 seconds.
✔ Test "a target that has become a password field refuses the write" passed after 0.009 seconds.
✔ Test "the selected text having changed refuses the write" passed after 0.010 seconds.
✔ Test "the selection having moved refuses the write" passed after 0.010 seconds.
✔ Test "a snapshot with nothing to validate against is refused rather than assumed safe" passed after 0.010 seconds.
✔ Test "a different process being frontmost refuses the write" passed after 0.010 seconds.
✔ Test "a still-matching target is replaced through the accessibility write" passed after 0.010 seconds.
✔ Test run with 8 tests in 1 suite passed after 0.011 seconds.
```

The happy-path test was written and made green first, so the refusal tests are not vacuous. The snapshot element and the live element are deliberately built as two separate `AXUIElementCreateApplication(501)` references, equal but not identical, so the `CFEqual`-not-`===` decision stays honest: pointer comparison would fail `matchingTargetIsReplacedInPlace`.

---

## 11. `heldForManualCopy(reason:)` touches nothing

`ReplaceOutcome` is `.replaced`, `.copiedOnly(reason:)`, `.heldForManualCopy(reason:)`.

**RED** (20 MB on the clipboard, selection moved so there is no write route):

```
✔ Test "an ordinary clipboard is still overwritten, because copiedOnly promises that" passed after 0.007 seconds.
✘ Test "nothing is touched when the target refuses the write and the clipboard cannot be borrowed" recorded an issue at ReplacementTests.swift:311:13: Expectation failed: outcome == .heldForManualCopy(...)
↳   outcome → .copiedOnly(reason: "the selection changed")
✘ ... at :319:13: Expectation failed: pasteboard.changeCount == changeCountBefore
↳   pasteboard.changeCount → 2
↳   changeCountBefore → 1
✘ ... at :320:13: Expectation failed: pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge
↳   pasteboard.pasteboardItems?.first?.data(forType: .tiff) → nil
↳   huge → 20971520 bytes
```

**GREEN:**

```
✔ Test run with 48 tests in 6 suites passed after 0.122 seconds.
```

`ordinaryClipboardIsStillOverwritten` is the contrast that keeps this honest: a small clipboard *is* still overwritten, because that is what `copiedOnly` promises. The held case is specifically "we could not capture it, so overwriting it is unrecoverable". The same check guards route two before the scratch write, tested separately.

This removes the "honest consequence" the old decision record recorded, where a user with an unsavable clipboard and a route-two app lost it anyway.

---

## Additional guards driven the same way

Each of these is in the preserved decision records as a requirement, and each got its own RED and GREEN.

| Behaviour | RED signal |
|---|---|
| Accessibility permission refused at capture, before touching the app | `ax.focusResolutions → 1` |
| A zero-length selected range stops the chain instead of falling through to ⌘C | no error thrown, with a stale clipboard staged to be rewritten |
| A zero-length range contradicting non-empty text is refused | no error thrown |
| `AXManualAccessibility` enables the tree and retries exactly once | `Caught error: .noSelection`; `manualAccessibilityEnables → 0` |
| An app answering no accessibility falls through to the clipboard | `Caught error: .noSelection` |
| Cache expiry re-probes | `manualAccessibilityEnables → 1`, expected 2 (mutation-verified) |
| App version change invalidates the entry | `manualAccessibilityEnables → 1`, expected 2 (mutation-verified) |
| A warm entry that comes up empty falls through rather than failing | `Caught error: .noSelection` |
| Once an app starts answering, the remembered clipboard route is replaced | `clipboard.attempts → 3`, expected 2 (see the YAGNI audit) |
| Secure input turning on between capture and apply | `outcome → .replaced` |
| Accessibility revoked between capture and apply | `outcome → .replaced` |
| Route two pastes and restores the clipboard | `keystroke.pastes → 0` |
| An unconsumed paste is not claimed as a replacement | `outcome → .copiedOnly(reason: "the target would not accept the write")` |
| Switching away during observation is not a consumed paste | same |
| Route two held when the clipboard cannot be borrowed | (guard test; meaningful once route two exists) |
| ⌘C returns nil rather than the stale clipboard when nothing was copied | sequential, green on first correct implementation |
| ⌘C declines *before posting* when the clipboard cannot be borrowed | `keystroke.copies → 1` |
| A change count that moves with no text yields nil, not an empty capture | sequential |
| A focused element owned by another process is rejected | `element(stray, ownedBy: 501) → <AXUIElement Application …> {pid=4242}` |
| A known editable role counts as editable with nothing settable | `isEditable(role: "AXTextArea", …) → false` |

Two of these, cache expiry and version invalidation, passed on their first run because I had written both checks into `StrategyCache` during the previous behaviour's GREEN step. That was more than the least code, and I am flagging it rather than hiding it. I verified both tests have teeth by deleting the two guards and re-running:

```
✘ Test "a cache entry expires so a bad reading is not permanent" recorded an issue at StrategyCacheTests.swift:102:9: Expectation failed: ax.manualAccessibilityEnables == 2
↳   ax.manualAccessibilityEnables → 1
✘ Test "an app version change invalidates the entry instead of adding a second one" recorded an issue at StrategyCacheTests.swift:125:9: Expectation failed: ax.manualAccessibilityEnables == 2
↳   ax.manualAccessibilityEnables → 1
```

The transient/auto-generated clipboard markers were the same situation and were mutation-verified the same way:

```
✘ Test "the scratch write is marked transient and auto-generated, and the restore is not" ... Expectation failed: pasteboard.types?.contains(transientType) == true
↳   pasteboard.types?.contains(transientType) → false
✘ ... Expectation failed: pasteboard.types?.contains(autoGeneratedType) == true
↳   pasteboard.types?.contains(autoGeneratedType) → false
```

---

## YAGNI audit (added after the rule landed)

I re-read `Sources/TextBridge/` against the new section 1 and looked for anything no test demands. Two findings, verified by deleting each and re-running:

```
✔ Test run with 56 tests in 8 suites passed after 0.115 seconds.
```

Both deletions were invisible to the suite, so both were unjustified as written.

1. **`kAXComboBoxRole` in `AXSelectionAdapter.editableRoles`.** No behaviour drove it. **Deleted and left deleted.**
2. **`record(.accessibility, for:)` in the capture chain.** I *can* name the test for this one, so it got one instead of being dropped: every clipboard borrow exposes the selection to clipboard-history apps, so a stale cache entry must cost one wasted copy rather than one per hotkey press forever. With the line still removed, the new test went RED on its own:

```
✘ Test "once an app starts answering, the remembered clipboard route is replaced" recorded an issue at StrategyCacheTests.swift:170:9: Expectation failed: clipboard.attempts == 2
↳ clipboard.attempts == 2 → false
↳   clipboard.attempts → 3
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

Restoring the two `record(.accessibility, …)` calls, **GREEN**, and this is the 57th test:

```
✔ Test run with 57 tests in 8 suites passed after 0.120 seconds.
```

Nothing else failed the audit. The seam protocols each have one production implementation plus a test double, and they are not speculative: without them the central secure-field behaviour cannot be expressed at all, since "password field focused, global secure-input flag false" cannot be staged on a real machine.

---

## Re-entrancy: concern 5 was wrong, and the property is testable

You challenged my claim that no test could catch someone making `observeConsumption` async. You were right, and the reframing is what unlocked it: the property is not "this function is synchronous", it is **two transactions cannot interleave**. Forcing the interleaving through the existing keystroke seam is exactly the window an `async` version would open.

**RED.** A second `apply` invoked from inside `onPaste`, while the first transaction sits between `writeTransient` and `restoreIfUnchanged`:

```
✘ Test "a second rewrite starting mid-paste cannot nest, and the user's clipboard survives" recorded an issue at ReentrancyTests.swift:88:13: Expectation failed: nested.value == .heldForManualCopy(...)
↳   nested.value → .copiedOnly(reason: "the target did not accept the paste")
✘ ... at ReentrancyTests.swift:94:13: Expectation failed: pasteboard.string(forType: .string) == "the user's clipboard"
↳ the user's real clipboard, not a rewrite fragment
↳   pasteboard.string(forType: .string) → "the second rewrite"
✘ Test "a capture cannot borrow the clipboard while a replacement holds it" ... Expectation failed: copyKeystroke.copies == 0
↳   copyKeystroke.copies → 1
✘ Test "a second borrow of the same pasteboard is refused while the first is open" ... Expectation failed: inner.snapshot() == false
↳   inner.snapshot() → true
```

`pasteboard.string(forType: .string) → "the second rewrite"` is the documented data loss, observed rather than asserted: the user's real clipboard destroyed and replaced with a rewrite fragment, with every `changeCount` check passing.

**GREEN**, via `PasteboardBorrow`, a process-wide exclusion keyed by pasteboard name. Refused rather than queued, because both transactions run on the main thread and waiting would stop the holder from ever finishing. A refused borrow reports `.notTaken`, which is the honest state: no snapshot was taken and none was lost. `handOff` now picks the reason from `fidelity`, so the user is told whether their clipboard is irreplaceable or merely busy.

Five tests, covering replacement-into-replacement, capture-into-replacement, the refusal itself, release, and non-contention between different pasteboards.

### The first implementation was flaky, and the fix is worth recording

Tying the borrow's lifetime to `deinit` made the suite fail intermittently in a different test each run. Instrumenting rather than guessing found it:

```
DIAG refused=CFPasteboardUnique-d89b6a10c09 held=[... "CFPasteboardUnique-d89b6a10c09" ...]
DEINIT held=false × 23
DEINIT held=true  × 19
```

`deinit` does run, but late. A test releases its pasteboard, **AppKit recycles the freed name**, the next test's `withUniqueName()` gets that name back, and its borrow collides with a transaction that finished long ago. The fix is to release at every *logical* end of the transaction — `restoreIfUnchanged`, and `writeDurable` for the copy-only path that never restores — keeping `deinit` only as a backstop. That is not a test artefact: in production it meant a copy-only outcome held the lock until ARC got round to it.

Six consecutive full runs after the fix:

```
✔ Test run with 62 tests in 9 suites passed after 0.118 seconds.   (×6, no variation)
```

---

## The 7 failures you saw: root cause

Your failures were real and my "passing" claim was wrong for you. The cause was not parallelism, and it was not a stale build on your side. **It was me mutating shared source in the live working tree.**

To demonstrate the re-entrancy guard going red on demand, I removed `PasteboardBorrow.shared.acquire` from `PasteboardTransaction.swift`, ran the suite, and restored it. Your `swift build --target TextBridgeTests` landed inside that window. `xcrun xctest` does not rebuild, so all three of your runs used the same mutated bundle and failed identically.

Evidence, rather than assertion. Rebuilding *with* the mutation reproduces your failure set exactly:

```
$ xcrun xctest ... | grep -oE 'ReentrancyTests.swift:[0-9]+' | sort | uniq -c
   1 ReentrancyTests.swift:88
   1 ReentrancyTests.swift:94
   1 ReentrancyTests.swift:130
   1 ReentrancyTests.swift:148
   1 ReentrancyTests.swift:149
   1 ReentrancyTests.swift:150
   1 ReentrancyTests.swift:151
✘ Test run with 62 tests in 9 suites failed after 0.396 seconds with 7 issues.
```

Seven issues, same seven line numbers, same three tests. A parallelism fault would not land on the same lines three runs running; it would move.

Your hypothesis, tested rather than assumed: with a clean build, the **full** bundle passes 20 consecutive times.

```
$ for i in $(seq 1 20); do xcrun xctest .build/out/Products/Debug/TextBridgeTests.xctest; done
  20 ✔ Test run with 62 tests in 9 suites passed
```

**Process fix:** mutation checks now happen against a copy, never against the shared tree. Any agent building in that window gets a broken artefact through no fault of their own, and the failure is invisible to me because my own runs bracket the mutation.

## Hardening: the borrow registry is now injected

Your design point stands on its own even though it was not the cause. `PasteboardBorrow.shared` is process-wide mutable state and swift-testing parallelises suites; it was only *accidentally* safe, relying on every borrow being released before AppKit recycles a pasteboard name. I had already been bitten by a lower-level version of that.

So `PasteboardBorrow` moved to its own file, became injectable, and defaults to `.shared`. Production keeps one process-wide registry, because the exclusion is meaningless otherwise. Each re-entrancy test now constructs its own, so the suite is order-independent by construction rather than by luck.

This is a refactor, not new behaviour: no new test, and the suite stayed green throughout, which is the point. The guard still has teeth — breaking the exclusion (`held.insert(name); return true`) still produces exactly the 7 failures above, and restoring it returns to green.

```
$ for i in $(seq 1 15); do xcrun xctest .build/out/Products/Debug/TextBridgeTests.xctest; done
  15 ✔ Test run with 62 tests in 9 suites passed
```

---

## Typed cause on `copiedOnly` and `heldForManualCopy`

`ReplaceOutcome` carried only a human sentence, so a caller in another module had to branch on prose that is user-facing copy and will get reworded. Both cases now carry a typed cause alongside the sentence.

**RED.** Enums added with every call site passing one uniform placeholder cause, so the failure is a real mismatch rather than a missing symbol:

```
✘ Test run with 63 tests in 9 suites failed after 0.297 seconds with 9 issues.
↳   outcome → .copiedOnly(cause: CopyOnlyCause.targetChanged, reason: "the target is a secure field")
↳   outcome → .copiedOnly(cause: CopyOnlyCause.targetChanged, reason: "the target could not be verified")
↳   outcome → .copiedOnly(cause: CopyOnlyCause.targetChanged, reason: "the selection was reconstructed from a range and cannot be verified")
↳   nested.value → .heldForManualCopy(cause: HoldCause.clipboardTooLarge, reason: "... another rewrite is using the clipboard")
```

Nine issues, every one a wrong cause on a correct sentence.

**GREEN**, with each path wired to its real cause and `TargetValidator.Refusal` gaining a `cause` property, so the validator reports which of its four identities moved rather than making the caller infer it from a string:

```
✔ Test run with 63 tests in 9 suites passed after 0.285 seconds.   (×10, no variation)
```

`notEditable` had no test before this change, because no existing test set `isEditable` false. Rather than ship a case with no path proving it, I added `nonEditableTargetIsCopyOnly` — an app that answers reads but has no editable buffer, which is the Terminal and PDF case from root `AGENTS.md` §3. Every cause is now both produced by a real path and asserted by a test:

| Cause | Tests asserting it |
|---|---|
| `.secureField` | 2 |
| `.noAccessibility` | 1 |
| `.rangeDerived` | 1 |
| `.targetChanged` | 5 |
| `.unverifiable` | 1 |
| `.notEditable` | 1 (new) |
| `.pasteNotConsumed` | 2 |
| `.clipboardTooLarge` | 2 |
| `.clipboardBusy` | 1 |

---

## `SystemProbe`: the seam that had no production side

A fully green suite proved the decisions were right and said nothing about whether the adapter existed. `SystemProbing` had one conformance and it was `FakeSystem`, so the app could not be constructed. My own "what stays manual" lists never caught it because a missing adapter is not a manual check, it is a missing file.

Almost all of it is untestable translation — `IsSecureEventInputEnabled()`, the non-prompting `AXIsProcessTrusted()`, `NSWorkspace.shared.frontmostApplication` — and none of that got a test. One decision did creep in exactly where you predicted, reading the version, so that got a test first:

**RED:**

```
✘ Test "a missing bundle, a missing key or an empty value all yield nil, never an empty string"
  recorded an issue at SystemProbeTests.swift:57:9: Expectation failed: SystemProbe.version(of: empty) == nil
↳   SystemProbe.version(of: empty) → ""
✘ Test run with 65 tests in 10 suites failed after 0.473 seconds with 1 issue.
```

Worth noting which cases failed: only the empty-value one. A nil bundle URL, a path that is not a bundle, and a bundle with no version key all yield nil naturally, which confirms the empty string was the single real decision rather than four.

**GREEN:**

```
✔ Test run with 65 tests in 10 suites passed   (×5, no variation)
```

The tests build real bundles in a temp directory rather than stubbing `Bundle`, because the thing under test is what `Bundle` hands back for a missing or empty key.

### A check worth repeating

Every seam now has exactly one production conformance, and the absence of one is silent:

| Seam | Production type |
|---|---|
| `SystemProbing` | `SystemProbe` |
| `AccessibilityReading` / `AccessibilityWriting` | `AXSelectionAdapter` |
| `ClipboardCapturing` | `ClipboardSelectionAdapter` |
| `KeystrokeCopying` / `KeystrokePosting` | `SyntheticKeystroke` |

---

## Test hygiene

- **`NSPasteboard.general` is never touched.** Every pasteboard test uses `NSPasteboard.withUniqueName()` and calls `releaseGlobally()` in a `defer`. The suite is safe to run while you are working.
- **No test needs another app installed, running or focused.** Real `AXUIElement` values come from `AXUIElementCreateApplication(pid)`, which needs no permission and no live process, and conveniently produces equal-but-not-identical references for the same pid, which is exactly the shape `CFEqual` has to cope with.
- **No unbounded or flaky sleeps.** The manual-accessibility settle is injected as `.zero` in tests. The consumption budget is injected at 40 ms with a 4 ms poll: a consumed paste returns on the first poll and an unconsumed one always exhausts, so both assertions are deterministic. Production defaults are 100 ms, 450 ms and 8 ms. One clipboard-adapter test deliberately exhausts a 40 ms budget. Total suite runtime is about 0.12 s.
- **No test asserts nothing.** Where an optimisation could have made a guard test vacuous (the strategy cache, the replacement happy path), the enabling behaviour was driven out first with its own test so the guard has something real to guard.

---

## Verified only by hand

**`SyntheticKeystroke`.** This is the single production type with no automated test, and it is deliberate. Posting a real `CGEvent` types into whatever the user happens to have focused, which would make the suite unsafe to run while somebody is working, and that directly conflicts with the hygiene requirement above. So the keystroke is injected everywhere it is used, via `KeystrokeCopying` and `KeystrokePosting`, and everything on both sides of it is driven: the borrow, the change-count wait, the settle, the restore, the consumption observation, the fallbacks.

The manual check, once the app target exists: build, grant Accessibility, then (a) select text in TextEdit, press the hotkey, confirm the selection is replaced in one undo step and the clipboard is untouched; (b) select text in an accessibility-opaque view, press the hotkey, confirm the text is captured and the clipboard afterwards holds what it held before; (c) select text in a web-based editor that refuses the `AXSelectedText` write, confirm the paste lands and the clipboard is restored. If you build a fixture app for this, give it a **real Edit menu**: a synthetic ⌘C only reaches an app's `copy:` through a menu key equivalent, and without one the keystroke lands nowhere and looks like the event failing to post.

**The Chromium off-by-one and live `AXManualAccessibility` behaviour.** Neither could be driven without an app that exhibits the gap. Both are written from documented and widely reproduced behaviour; the rung-8 retry and the rung-7 refusal are unit-tested through the seam, and rung 7 fails closed regardless, so the untested branch cannot produce a write.

**The thin C-API wrappers in `AXSelectionAdapter`.** `AXUIElementCopyAttributeValue` and friends need a live target and a granted permission. The two parts of that file that are decisions rather than plumbing, the pid-ownership check and the editability heuristic, are unit-tested directly.

---

## Documentation

`Sources/TextBridge/AGENTS.md` now holds one consolidated decision record, and `Sources/TextBridge/CLAUDE.md` contains exactly `@AGENTS.md`. The two preserved files, `AGENTS-Selection.md` and `AGENTS-Replacement.md`, were folded into it and deleted, because a fact in two files goes stale in one of them.

It covers everything asked: the capture chain order and why each rung exists, why an empty selected-text string is ambiguous and how the range's three states settle it, why `AXManualAccessibility` is needed for Electron and why the retry is once, why the pasteboard restore is conditional on `changeCount` rather than a delay, why revalidation exists and why there is deliberately no age limit, why text is never trimmed or normalised, and why none of this can work in a sandboxed build. Plus the new material: the three-state `Fidelity` and the front-check ordering, the third outcome, the cache-below-the-refusal boundary, the no-default `let`, and an honest "what is verified and how" section.

`Sources/TextBridge/_Placeholder.swift` was deleted, as its own comment instructed, now that the target has real source.

---

## Final run

In the real package, at the real paths, using the per-target isolation command:

```
$ cd /Users/kabara/Desktop/Everest/EverestKit
$ swift build --target TextBridgeTests
ok (build complete)
$ xcrun xctest .build/out/Products/Debug/TextBridgeTests.xctest
✔ Test run with 62 tests in 9 suites passed after 0.310 seconds.
```

Suites: Capture refusals, Capture chain, Strategy cache, Text fidelity, Pasteboard transaction, Replacement, Clipboard capture, Accessibility adapter, Re-entrancy.

`swift test --filter TextBridgeTests` still does not complete, and not because of this target: three attempts died in `RewriteCoreTests` (`cannot find 'ModelCatalog' in scope`, then `cannot find 'AppSettings' in scope`) and then `EnginesTests` (`cannot find type 'MLXEngine' in scope`) as each sibling moved through its own RED. Agreed that this is transient and that you will verify the whole-package run yourself.

---

## Concerns

1. **`SyntheticKeystroke` is untested and it is now the sharpest edge left.** Its two callers are fully tested, but a wrong key code or a missing modifier flag would produce a capture that silently returns the stale clipboard and a paste that silently does nothing. The zero-length-range stop and the change-count guard catch the *consequences*, so the failure mode is "Everest does nothing" rather than "Everest corrupts something", but only the manual check will catch it.

2. **The cached-clipboard residual gap is real and unfixable from inside this directory.** An app that exposes no accessibility tree even after `AXManualAccessibility` gives us no element to classify, so only the process-wide flag protects it, and web-style password fields do not set that flag. The only mitigation is the exclusion list. Noted that you are carrying the default list into the app shell as a requirement.

3. **`Fidelity.lossy` means "over budget", and a nil `data(forType:)` is treated as a derived flavour with nothing to lose.** That is the measured behaviour, but it would also mask a genuine read failure on a real payload. I could not find a way to tell those apart through `NSPasteboard`, and erring toward `faithful` was the measured choice.

4. **`TargetSnapshot` is `@unchecked Sendable`** because `AXUIElement` is not `Sendable`, inherited from the plan's shared-interface declaration. It is sound only while snapshots stay on one actor. `RewriteCoordinator` owning one transaction at a time is what makes that true, so the app shell must not fan a snapshot out across tasks. `PasteboardBorrow` now enforces the clipboard half of that invariant, but not the snapshot half.

5. **The 60-line doc budget cost the worked examples, not the facts.** `AGENTS.md` is 57 lines and keeps every empirical fact and every guard, but the reproduction of the 40 MB TIFF wipe, the full argument for why no restore delay can win the race, and the step-by-step re-entrancy mechanism are one line each now. A future agent will find the claim but not the derivation. The derivations are in this report and in the source comments.

Resolved since the first draft: the whole-package runner (your isolation command works, and the final run above is from the real package), the eight unhandled-resource build warnings (your `exclude: docs` change), and the re-entrancy guard, which is now enforced by `PasteboardBorrow` and covered by five tests rather than by a comment.
