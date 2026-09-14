# Selection: reading text out of somebody else's app

Decisions and rationale for `Improve/Selection/`. Read this before changing anything here. Written 2026-09-14, verified against macOS 26.0 / Xcode 27 / Swift 6.4.

This directory answers one question: *what has the user selected, and where is it?* Writing the rewrite back is `Improve/Replacement/`, and the two halves are designed together. Read both.

---

## The one paragraph a new agent needs

Reading a selection out of an arbitrary Mac app is not a function call, it is a negotiation with an app that may not want to talk. Apps disagree about which accessibility attributes they implement, some build no accessibility tree at all until asked, and a few answer nothing ever. So capture is a chain of increasingly desperate attempts, and every rung of the chain has a reason to exist. **The order carries weight and the refusals come first.** If you shorten the chain you will break a category of app you have not tested; if you reorder the refusals you will read a password.

---

## Files

| File | Role |
|---|---|
| `TargetSnapshot.swift` | The three shared types: `TargetSnapshot`, `CaptureError`, `ReplaceOutcome`, plus `CaptureLimits`. |
| `AXSelectionAdapter.swift` | Stateless wrappers over the C accessibility API. No policy. Also the `isSecureElement` and `isEditable` predicates. |
| `ClipboardSelectionAdapter.swift` | The synthetic Command C path, and `SyntheticKeystroke`, which `Replacement` also uses for Command V. |
| `SelectionCoordinator.swift` | All the policy: refusal order, the chain, the per-app strategy cache. The only entry point. |

`ReplaceOutcome` lives in `TargetSnapshot.swift` rather than next to `ReplacementService` because the MVP plan declares all three shared types in that file and other tasks consume them verbatim. Do not move it without updating the plan.

`SyntheticKeystroke` lives in `ClipboardSelectionAdapter.swift` because synthesising Command C *is* the clipboard capture path. `ReplacementService` reaches across for Command V. If you go looking for the Command V code in `Replacement/` and cannot find it, that is why.

---

## The capture chain, rung by rung

`SelectionCoordinator.capture()` runs these in order. Each rung exists for a class of app the previous rung cannot serve.

**0. Secure input flag.** `IsSecureEventInputEnabled()` from Carbon. A process-wide flag that any app can set: password managers, the login window, Terminal's Secure Keyboard Entry. Checked first because it needs no permission, costs nothing, and is true exactly when the user is doing something we must stay out of. It is also the moment synthetic keystrokes stop being delivered, so continuing would fail anyway.

**1. Frontmost app identity.** From `NSWorkspace`, which needs no accessibility permission. Gives us pid, bundle identifier, and version.

**2. Exclusion list.** Refused here, before a single accessibility call is aimed at the app. The list arrives as a constructor argument and is a mutable property; see "Why the exclusion list is a var" below.

**3. Accessibility permission.** `AXIsProcessTrusted()`. Everything after this point needs it, including posting the synthetic keystroke.

**3a. Focus resolution.** `resolveFocus(pid:)` finds the focused element and, if the app answers nothing at all, switches on its accessibility tree with `AXManualAccessibility` and asks again. This sits here, above everything else, because rung 4 needs an element to inspect and the apps most likely to hide a password field are exactly the ones whose tree is off.

**4. Secure role check.** `refuseIfSecure`, on that element, before any text is read and before any keystroke is posted. Step 0 catches a password manager that has taken secure input. This catches a password field that has not, which is the normal case for a web or Electron password input: measured, those set the secure subrole and do **not** set the process-wide flag.

**The strategy cache is consulted only after rung 4.** This is a correctness boundary, not an implementation detail. An earlier version read the cache first and sent a remembered `.clipboard` app straight to the synthetic copy, which skipped rungs 3a and 4 entirely and left nothing but the global flag between Everest and a web password field. The cache is allowed to skip *work*. It is never allowed to skip a *refusal*. If you move the cache lookup above `refuseIfSecure`, you have reintroduced that bug.

**5. `AXSelectedText`.** The app's own answer to "what is selected". Preferred whenever it is non-empty, even when a range is also available. See "Why AXSelectedText beats AXStringForRange".

**6. `AXSelectedTextRange`.** Read next, and it decides the ambiguous cases. See "Why an empty string is ambiguous".

**7. `AXStringForRange`.** The parameterized read, used when the app reports a range but returns nothing for `AXSelectedText`. Several text engines implement one and not the other.

**8. `AXManualAccessibility`, then retry once.** For Chromium and Electron. See below.

**9. Synthetic Command C.** Last resort. See below.

---

## Why an empty selected-text string is ambiguous, and the range is what settles it

`AXSelectedText` returning `""` means one of two completely different things:

- nothing is selected, or
- this app does not implement the attribute.

You cannot tell from the string. `AXSelectedTextRange` is what disambiguates, and it has three states that map cleanly onto three decisions:

| `AXSelectedTextRange` | Meaning | What we do |
|---|---|---|
| length zero | The app is telling us plainly: the caret is somewhere with nothing selected. | **Stop.** Throw `.noSelection`. Do not continue down the chain. |
| length greater than zero | Something is selected, the app just did not hand it over as a string. | Continue to `AXStringForRange`. |
| absent entirely | The app implements neither attribute. | Continue to manual accessibility, then the clipboard. |

**The zero-length case must stop the chain, not fall through to the clipboard.** This is the single most dangerous corner in the whole directory. If nothing is selected, Command C copies nothing, the clipboard still holds whatever the user copied ten minutes ago, and a naive implementation then reads that and rewrites it. The user watches Everest confidently rewrite a paragraph they are not looking at, or a URL, or text they copied out of their password manager. The bug is silent and looks like the model hallucinating rather than like a capture fault.

`ClipboardSelectionAdapter` carries the same guard independently: it reads the pasteboard **only after observing the change count move**. Two layers, because this one is unrecoverable and easy to reintroduce.

A zero-length range together with non-empty selected text is a contradiction, and it resolves the same conservative way: refuse. Trusting the text would mean writing the rewrite back through a zero-length range later, which inserts a second copy rather than replacing anything.

---

## Why `AXSelectedText` beats `AXStringForRange` when both work

Chromium and Electron have a long standing off-by-one in `AXSelectedTextRange`. Feed that range to `AXStringForRange` and you get a string shifted by a character: a leading space where a letter should be, a missing final letter.

The reason this matters more than it sounds: **the shifted text is still perfectly well formed prose.** No validator downstream can catch it. The model happily rewrites it, and the user gets back a sentence missing its first letter with no error anywhere.

`AXSelectedText` is the app's own answer and does not go through that arithmetic, so it wins whenever it has content. When it has content, the range is recorded only as an identity token for revalidation and is never used to reconstruct the text.

### Rung 7 is the one place the off-by-one is unmitigated, and it fails closed

`AXStringForRange` reconstructs the text *from the range*, by definition. That rung is entered only when `AXSelectedText` came back empty, which is precisely the population where preferring `AXSelectedText` offers no protection at all. So the text it returns may be shifted by a character at either end, and it is well formed prose either way, so nothing downstream can tell.

**Revalidation is structurally unable to catch this, and you must not try to fix it there.** `TargetValidator.compare` mirrors the capture chain on purpose. For such a snapshot it would re-read through the *same* shifted range, get the *same* shifted string, and confirm a match with itself. The four-identity check is a check for *change*, and nothing has changed; the reading was wrong from the start.

The fix is therefore at the rung, not at the gate. A capture that came through `AXStringForRange` sets `TargetSnapshot.isRangeDerived`, and `ReplacementService` refuses to write any snapshot with that flag, returning `.copiedOnly`. Same reasoning as the clipboard path, same outcome: without a trustworthy text-plus-range identity there is no safe write, so the rewrite goes to the clipboard and the user places it.

Losing the automatic replacement there is the correct trade. A rewrite the user has to paste is an inconvenience; a rewrite of text that was off by one character, written over a selection that was not quite what we read, is silent corruption of their document.

**This is also why the text is never trimmed.** See the dedicated section below.

---

## Why `AXManualAccessibility` is needed for Electron

Chromium keeps its accessibility tree switched off until something asks for it, because building and maintaining a full tree for a web page is expensive. Until it is asked, the entire subtree is invisible over accessibility: no focused element, no selected text, no range. That state is indistinguishable from an app with nothing selected, which is exactly why this rung exists rather than giving up at step 7. This branch is documented behaviour, not something measured here; see "What is verified" at the end.

Setting the undocumented `AXManualAccessibility` attribute to true on the **application** element is the request. It is not in the SDK, so the string is spelled out in `AXSelectionAdapter`.

Three things to know:

1. **The tree is not ready when the call returns.** It is built in response to the attribute write. `SelectionCoordinator.manualAccessibilitySettle` waits 100 ms and then re-resolves the focused element from scratch, because the element we failed to get before now exists.
2. **Retry once, never in a loop.** If the tree did not appear after the settle, it is not going to, and a retry loop turns a failed capture into a visible freeze on the main thread.
3. **We deliberately do not set `AXEnhancedUserInterface`.** It is the older flag with a similar effect on some apps, but it also changes window management behaviour in others, and toggling it on somebody's running app to read one sentence is not a trade worth making.

The flag persists for the life of the target process, so the next capture of the same app usually succeeds on the plain accessibility path. That is why the strategy cache must be a hint and not a gate.

---

## Why the strategy cache exists, and why it expires

A failed accessibility read is not free. It is synchronous cross-process IPC, it can cost up to the messaging timeout, and the chain makes several. Against an app that answers nothing, re-proving that on every hotkey press costs most of a second of frozen main thread.

So the working route is remembered per app. Three properties are deliberate:

- **Keyed by bundle identifier, with the version stored in the value.** A version mismatch replaces the entry rather than adding a second one, so the cache cannot grow without bound and the stale reading is gone rather than merely unreachable. An app upgrade invalidates naturally, because what we learned was learned about a different binary.
- **Expires after ten minutes** (`strategyReprobeInterval`). Without expiry, one bad reading pins an app to the clipboard path forever. An Electron app answers nothing until *something* enables its tree, and that something may have been a screen reader that has since quit, or the app may have relaunched. Self-healing matters more than the handful of milliseconds it costs.
- **A cached answer is never a gate.** A remembered clipboard app skips the accessibility chain, but if the clipboard comes up empty we fall through and probe properly. A stale entry costs one wasted copy, never a permanent downgrade.

**What a cached `.clipboard` entry actually skips, stated plainly:** rungs 5 through 9, the accessibility reads. It does **not** skip rungs 0 to 4. Secure input, app identity, the exclusion list, accessibility permission, focus resolution and the secure-role refusal all run first, on every capture, cached or not. `captureViaClipboard` then repeats the secure refusal immediately before the keystroke, because that is the point of no return: once another process has written the pasteboard on our behalf, nothing can be undone.

The cache is keyed per app, not per field, and that is the reason the repetition matters. An app is recorded as `.clipboard` because its tree was unavailable at one moment. Focus can be in a password field the next time, in the same app, with the entry still warm.

---

## Why the focused element is looked up twice, scoped to a pid

`AXSelectionAdapter.focusedElement(pid:)` asks the system-wide element first, then the application element, and requires the answer to belong to `pid`.

**Measured, not theoretical.** On macOS 26, `AXFocusedUIElement` on the system-wide element returns `kAXErrorCannotComplete` (-25204) against TextEdit while the identical query against TextEdit's own application element succeeds immediately. Treating that error as "nothing is selected" made Everest look broken in an ordinary Apple app. The system-wide element is still asked first because it reflects real keyboard focus including panels and helper processes; it is just not trustworthy alone.

**The pid check is a security check, not tidiness.** The exclusion list and the bundle identifier were evaluated against the frontmost process. An element owned by a different process would be text that was never checked against the user's list of apps Everest must stay out of. If system-wide focus has wandered, we use the frontmost app's own focused element instead.

---

## Why text is never trimmed, normalised, or cleaned

Three independent reasons, any one of which is sufficient:

1. **It changes what the user selected.** They chose those characters. Leading and trailing whitespace is often exactly what makes a rewrite fit back into the sentence around it.
2. **It breaks replacement.** `TargetValidator` compares the snapshot text against the live selection, exactly, character for character. A trimmed copy never matches, so a trimmed capture means the rewrite silently never gets written back anywhere.
3. **It papers over the Electron bug instead of fixing it.** The off-by-one is a *range* level problem. Trimming a stray leading space makes the symptom vanish in the one case where the shifted character happens to be whitespace and leaves it in every other case, while destroying legitimate whitespace everywhere. If you find yourself reaching for `trimmingCharacters`, the bug you are chasing is at the range level and this is the wrong file.

Verified: a selection of `"  spaced  \tand\ttabbed  "` round-trips through capture byte for byte.

---

## Why the exclusion list is a `var` and not a `let`

It arrives as a constructor argument, as the task requires, and is then a settable property. The user can edit the excluded apps in Settings while Everest is running. A value frozen at construction would go stale in a way nobody notices until Everest reads from a password manager the user had explicitly excluded. Task 5 should assign to it when settings change.

Matching is case-insensitive and exact. No prefix or wildcard matching, because a user typing `com.apple` and silently excluding every Apple app would be a surprise.

The app's own bundle identifier is **not** special-cased. If Everest should refuse to read its own windows, Task 5 adds it to the injected list. Keeping all exclusion policy in one injected list is the point.

---

## The clipboard path, and its unavoidable cost

Last in the chain for three reasons. It is the only path that disturbs the user's clipboard. It is the only path that depends on the target having a working Edit menu Copy. And it leaks.

**One residual gap, stated so nobody assumes it is covered.** The secure-role refusal needs an element to inspect. An app that exposes no accessibility tree at all, even after `AXManualAccessibility`, gives us nothing to check, so only the process-wide secure-input flag applies there. That is the irreducible cost of having this rung: an app we cannot read is an app whose fields we cannot classify. The mitigation available to the user is the exclusion list. In practice native password fields set the global flag and web or Electron ones expose the subrole once the tree is on, so the uncovered case is a toolkit that does neither.

**The leak is unavoidable and you should know about it.** During a synthetic Command C, the *target app* writes the selected text to the pasteboard. That write is not ours, so we cannot mark it transient, and any clipboard history app the user runs will record it. We restore the user's clipboard immediately afterwards, which limits the exposure to a few hundred milliseconds, but a history app watching the pasteboard will have caught it. This is a real argument for keeping the accessibility paths healthy rather than letting apps drift onto the clipboard path.

Timing is bounded, never fixed: `copyBudget` 400 ms to see the change count move, then `settleBudget` 120 ms to get readable text, polling every 8 ms and returning the instant it has an answer. A fast app costs about ten milliseconds. The settle step exists because an app clears the pasteboard and writes it in two steps, so there is a window where the count has moved and the data has not landed.

**The waits block the main thread and must not pump the run loop.** `capture()` is synchronous by design. Pumping the run loop from inside a hotkey handler would let a second hotkey press re-enter the capture chain while the first is halfway through borrowing the clipboard. Blocking is the lesser problem, and only on the path that accessibility-hostile apps reach.

---

## Sandbox: this code cannot work in a Mac App Store build

`AXUIElementSetAttributeValue` and `AXUIElementCopyElementAtPosition` do not function under App Sandbox, **even when the user has granted Accessibility permission**. The permission prompt never appears and `AXIsProcessTrusted()` returns false permanently. Both halves of this product are blocked, so there is no partial or degraded sandboxed mode to fall back to.

Do not add `com.apple.security.app-sandbox` to this target, and do not accept a task framed as "make Everest sandbox-compatible" without telling the human it means deleting the feature. Rectangle, BetterTouchTool and Hammerspoon all ship outside the Mac App Store for exactly this reason.

---

## What is verified, and how

Everything below was run against real apps on macOS 26 during implementation. The test harnesses were throwaway and live outside the repo; there is no Xcode project yet (Task 5) and no XCTest target for this directory.

Confirmed working against TextEdit: capture of the exact selection, pid and bundle identifier and version, range, role, editability, byte-for-byte whitespace fidelity, zero-length refusal, exclusion refusal, synthetic Command C returning the selection with the clipboard restored afterwards, and the guard that a copy with nothing selected returns nil rather than the stale clipboard.

Confirmed against a real `NSSecureTextField`: it reports **role `AXTextField`, subrole `AXSecureTextField`**. A role-only check would have missed it entirely. This is why `isSecureElement` checks both slots, and it is the empirical reason that function looks redundant and is not. A plain `NSTextField` in the same app captured normally, so the refusal is specific rather than a blanket failure.

Confirmed against a purpose-built app with an accessibility-opaque view and a field carrying the secure *subrole* with no secure event input, which is the shape of a web password input: the opaque view falls through to the clipboard rung and is captured, which records `.clipboard` for that bundle; with that cache entry warm, focusing the fake-secure field makes `capture()` throw `.secureField`, posts no keystroke, and leaves the clipboard untouched. `IsSecureEventInputEnabled()` was measured as **false** throughout that phase, so the subrole check, not the global flag, is what refused. The same app captures normally again afterwards, so the refusal is about the field rather than a permanent poisoning.

Not verified live: the Electron and Chromium branch (`AXManualAccessibility` and the retry), and the `AXStringForRange` branch, because both need an app that exhibits the relevant gap and neither was safe to drive on the user's machine. They are written from the documented and widely reproduced behaviour. Treat them as the least proven code here. Note that rung 7 now fails closed regardless, so an untested branch cannot produce a write.
