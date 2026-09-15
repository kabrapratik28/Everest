# Overlay: the floating panel

Borderless panel at the bottom of the screen; streams the rewrite in, goes away. `show(_:)`, `update(_:)`, `update(from: RewriteEvent)`, `dismiss()`, `onCancel` / `onPickStyle` / `onCopy`.

Almost none of a floating panel is about windows. Words, icons, placement, the height cap, auto-dismiss, throttling, key mapping: arithmetic and lookup, all tested. `Seams.swift` holds the entire boundary — `PanelSurface`, `KeyMonitoring`, `PanelClock`. Below it sit `NSPanelSurface`, `NSEventKeyMonitor`, `RunLoopPanelClock`, `PanelAppearance.current()` and the two SwiftUI views: no decisions, no tests, hand-checked. **Nothing below a seam decides anything.** An `if` in `RewriteView` about *what* to show, or a number in `NSPanelSurface` about *where*, belongs above it — that rule is what keeps the untested part small.

## Non-activating while a write is intended; key once it is not

`.nonactivatingPanel` + `.borderless`, and `canBecomeKey` set per state from `PanelState.acceptsKeyWindow`. Activating makes the source app resign active. Its selection stops being live, `AXSelectedText` goes empty or stale, and capture fails — no crash, no log line, no failing test. Make it a plain `NSWindow` and the product silently stops working. Hence also `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`; not `orderFront(_:)` (an inactive app's can be deferred) and not `makeKeyAndOrderFront(_:)`. `.borderless` is part of the guard, not cosmetics: a titled window can become key. That cost is only worth paying while a write is still intended:

| State | Key | Why |
|---|---|---|
| `capturing`, `preparing`, `generating`, `applying`, `stylePicker` | no | a write is still intended; the picker included, since activating loses the source app frontmost and revalidation then downgrades to `copiedOnly` |
| `success` | no | auto-dismisses, asks nothing of the user |
| `readOnly`, `targetChanged`, `heldForManualCopy`, `refused`, `error` | yes | terminal, nothing will be written, and only a key window can *consume* ⌘C |

## Keys come from an `NSEvent` monitor

A non-key panel has no first responder, so `.onKeyPress`, `.keyboardShortcut`, `@FocusState`, `List(selection:)` and `cancelOperation(_:)` all do nothing — each looks right in an Xcode preview, where the host *is* key. That is why `StylePickerView` is a `VStack` over a plain `Int`. Two monitors: **global** (another app frontmost — the normal case) and **local** (global monitors never see our own process, so without it Escape dies exactly when the user is looking at us). Only the local one can consume, by returning `nil`.

**Teardown is structural, not disciplinary.** A global key-down monitor watches every keystroke in every app while installed; "remember to remove it" is a habit, not a guarantee. `install` returns a `KeyMonitorHandle` whose `deinit` removes them, and the controller holds the only reference — clearing it removes them, releasing the controller removes them. No reachable state has them installed with the handle lost. Four tests hold that, including the error path and controller deallocation. Monitors stay armed through terminal states until `dismiss()`, so a result panel on its timer still closes on Escape.

**A global monitor observes; it cannot consume.** Pressing `3` in the picker selects style 3 **and types a `3` into whatever app is frontmost.** Correct trade: consuming needs a key window, which costs the selection. (The alternative is a `CGEventTap` with its own permission.)

> **For the app shell: capture the selection *before* showing the picker.** Otherwise a stray digit lands in the very text about to be rewritten. Nothing in this directory can prevent that.

**⌘C, never Return.** Return is too dangerous for a convenience binding: if the key-window logic ever regressed, a leaked Return sends a Slack message or submits a form. A leaked ⌘C copies the frontmost app's own selection, which is harmless, and it is the universal idiom. Consuming still matters — if the panel were not key, the frontmost app's own copy would land *after* ours and overwrite the rewrite on the clipboard. `handle` therefore returns `state.acceptsKeyWindow`: acting on a key is not the same as swallowing it, and claiming a non-key panel consumed an event would make the local monitor eat something the frontmost app should see. `Keystroke.isPlain` is false when any of ⌘⌥⌃⇧ is held, so ⌘3 and ⇧3 pass through; ⌘C requires *exactly* ⌘. Picker keys do nothing outside the picker.

**Shortcuts are shown, or they do not exist.** This panel is up for two seconds with no menu bar, tooltip or onboarding. `PanelState.keyHints` is tested per state: ⌘C wherever there is a rewrite to copy, `esc` wherever the panel will not close itself. Each hint carries `performs: PanelKeyAction`, because **the hint row *is* the clickable control** — one affordance showing the shortcut, carrying the words and taking the click, rather than a button beside a caption (which left a bare glyph in one corner and its label in the other). Matching on the displayed words instead would break the first reword. Badges are keycaps — shape and weight, never colour alone — and `.accessibilityHidden(true)`, since a screen reader announces key equivalents through the standard mechanism.

## Bottom centre, not the caret

Caret anchoring needs `kAXBoundsForRangeParameterizedAttribute`, which rests on the same range reporting `TextBridge` documents as unreliable: many apps do not implement it, Chromium and Electron are inconsistent, and it returns empty rects, wrong coordinate spaces or scrolled-out lines — putting the panel off the display. A panel you cannot see is worse than a boring one. `PanelGeometry` is a pure function of a `CGRect`, so screens nobody has plugged in are testable. Its tests use a **negative-origin** screen: a frame from `width / 2` instead of `midX` passes at the origin and fails on a second display. The screen comes from the pointer, not `NSScreen.main` (that is the key window's screen), and is sampled once at `show()` so a growing panel cannot hop displays mid-stream. `minY` is constant per screen, so the panel grows upward rather than crawling down it. Height follows content to 40% of the visible frame, then `PanelLayout.scrolls` goes true and the document keeps its full height so the overflow is reachable rather than clipped. Width, inset and cap are clamped to the visible frame, because 40% of a short screen plus a fixed 96pt inset stops fitting.

## Streaming is throttled to ~16 ms

A 4B model emits faster than 60 Hz and every event is a full cumulative snapshot, so rendering each one relayouts a growing paragraph dozens of times a second against the decoder on the same thread. Dropping an intermediate snapshot is free — the next is a superset.

| Rule | Without it |
|---|---|
| The held snapshot is flushed on a timer | The last tokens never render; the rewrite stops a few words short |
| Only `generating` is throttled | A terminal state waits behind a timer showing a stale spinner |
| A non-streaming state clears the held one | A queued snapshot lands after the result and overwrites it |

Timer on `RunLoop.main` in `.common`: a default-mode timer stops firing while a scroll gesture or menu is up, freezing the text. Streaming auto-scrolls to the tail but stops once the user scrolls up — yanking someone back mid-sentence is worse than not following. The scroll position arrives through a `boundsDidChangeNotification` observer held in a `KeyMonitorHandle`, same ownership rule as the key monitors, because an observer nobody owns is that hazard one layer over; `postsBoundsChangedNotifications` must be set or it never fires. "At the bottom" is a *tolerance*, not an equality: offsets are fractional, so `==` would switch following off on the first gesture and never resume. `update(from:)` maps `.finished` to `.applying`, never to a terminal state: generation stopping is not the transaction succeeding, since validation and replacement still follow and can still fail.

## `heldForManualCopy` must never close itself

`autoDismissAfter` is `nil` for it and must stay `nil`. It is the state where the rewrite could be neither written back nor put on the pasteboard, so the panel holds the user's **only** copy and a timer deletes their work. `success` is the opposite and does dismiss. The test asserts the rule across all eleven states, so a twelfth that quietly holds text fails it.

## Accessibility is a requirement, not polish

`PanelAppearance` is three booleans and every consequence is a pure function of them: Reduce Motion drops the transition and indeterminate spinners (a *determinate* bar stays — position, not motion for its own sake); Reduce Transparency goes opaque, because translucency over arbitrary content is the worst thing you can do to contrast; Increase Contrast thickens borders and strips decorative tint. Read from `NSWorkspace`, not the SwiftUI environment, which is not populated for an `NSHostingView` in a non-key borderless panel. Sampled once per `show()` — an observer is one more thing to leak. **No state is signalled by colour alone**: a green check and a red cross at 14pt are the same grey glyph to one man in twelve. Two mechanisms, both needed — `symbolName` and `title` are `switch`es with no `default` (the compiler demands them), and `PanelStateKind` is a `CaseIterable` mirror so one test demands every case be *sampled and checked*, which the compiler cannot force. `accessibilityValue` omits the streaming text, because VoiceOver restarts its utterance on every change and would read the first three words at token rate; it does include refusal and error reasons, since a reason nobody can hear is not a reason.

## Things that will look like cleanups

Dropping `.nonactivatingPanel`, or making the panel key in a non-terminal state · binding Return to anything · `.onKeyPress` instead of monitors · keeping monitors armed between transactions · dropping the local monitor · returning `true` from `handle` unconditionally · hiding the keycap badges as "clutter" · collapsing the seams ("the indirection buys nothing" — it is why 60 tests exist here) · rendering every snapshot · deleting the flush timer ("the next token will render anyway": there is no next token after the last) · auto-dismissing `heldForManualCopy` · caret anchoring · treating Reduce Motion as optional.

**Tests:** `cd EverestKit && swift test --filter OverlayTests`. While other agents are mid-RED, isolate with `swift build --target OverlayTests && xcrun xctest .build/out/Products/Debug/OverlayTests.xctest`.
