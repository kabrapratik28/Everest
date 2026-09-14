# Task 4: Overlay UI — report

**Status: complete.** All six deliverables exist, typecheck clean under Swift 6 strict concurrency against the real `RewriteCore` module. Nothing outside `Improve/Overlay/` was touched.

## Files created

All under `/Users/kabara/Desktop/Improve/Improve/Overlay/`:

| File | Contents |
|---|---|
| `PanelState.swift` | The ten-case enum, exactly as specified, plus the presentation extension (`symbolName`, `title`, `detail`, `bodyText`, `isCancellable`, `isTerminal`, `isStreaming`, `showsActivity`, `accessibilityLabel`). Every one is an exhaustive `switch` with no `default`, so a new case forces the author to supply words and an icon. |
| `FloatingPanelController.swift` | `@MainActor final class` with `show(_:)`, `update(_:)`, `dismiss()`, `onCancel`, `onPickStyle`. Also holds `PanelModel` (the observable the views read) and `KeyMonitorPair` (the monitors). Adds one convenience, `update(from: RewriteEvent)`. |
| `RewriteView.swift` | `PanelAppearance` (the accessibility snapshot), `PanelMetrics` (shared geometry), `PanelChrome` (the background), `RewriteView` (the content). |
| `StylePickerView.swift` | The numbered list, driven by an `Int` in the model rather than by focus. |
| `AGENTS.md` | 16 KB of rationale covering all five required topics plus the picker's swallow limitation, the height measurement, and a "things that will look like cleanups" list. |
| `CLAUDE.md` | Exactly `@AGENTS.md\n`, 11 bytes, verified with `od -c`. |

## What was verified, and how

Full typecheck, which is above the stated bar of `-parse`. The `-I` path is the real built `RewriteCore`, so `import RewriteCore` and the `Preset` usage are genuinely resolved, not skipped:

```bash
cd /Users/kabara/Desktop/Improve/Improve/Overlay
xcrun swiftc -typecheck -target arm64-apple-macos26.0 -swift-version 6 \
  -I /Users/kabara/Desktop/Improve/RewriteCore/.build/out/Products/Debug \
  PanelState.swift RewriteView.swift StylePickerView.swift FloatingPanelController.swift
# exit 0, no errors, no warnings
```

Control: the same command without `-I` fails with `error: no such module 'RewriteCore'`, which proves the module is really being read rather than the import being ignored.

The required bar also passes, per file:

```bash
xcrun swiftc -parse -target arm64-apple-macos26.0 <file>.swift   # exit 0 on all four
```

`-swift-version 6` matters here: it means the `NSEvent` monitor closures, the `Timer` closure, and the `@MainActor` isolation all satisfy strict concurrency as written, which is the part most likely to have broken at Task 5 integration time.

Not verified, and not verifiable before Task 5: runtime window behavior, actual monitor teardown, the measured height of wrapped text, and whether `orderFrontRegardless()` places the panel correctly over a fullscreen app. These need a built app and a second application to point at.

## Requirements, point by point

1. **Non-activating panel.** `NSPanel`, `styleMask: [.nonactivatingPanel, .borderless]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `isOpaque = false`, `backgroundColor = .clear`, material drawn by SwiftUI in `PanelChrome`. Also `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `isExcludedFromWindowsMenu = true`, and ordered on screen with `orderFrontRegardless()` rather than `orderFront(_:)`, which an inactive app can defer.
2. **Key monitors.** Global plus local, installed by `startKeyMonitor()` from `show()` and removed by `stopKeyMonitor()`, which is the first statement of `dismiss()`. Leak-proofing is structural rather than disciplinary: the two tokens live in a `KeyMonitorPair` whose `deinit` removes them, and the controller holds one optional reference, so assigning `nil` removes them and so does releasing the controller. There is no reachable state with the monitors installed and the handle lost. `startKeyMonitor()` is idempotent.
3. **Geometry.** Bottom centre of the screen under the pointer (not `NSScreen.main`, which is the key-window screen and this app has no key window). 460pt wide, height measured from the content, capped at 40% of that screen's `visibleFrame`, `NSScrollView` beyond that. Origin recomputed from the bottom edge each resize so the panel grows upward.
4. **`PanelState`.** All ten cases, exact names and payloads.
5. **Accessibility.** `PanelAppearance` reads all three `NSWorkspace` flags and each changes rendering: no animation and no indeterminate spinner under Reduce Motion, opaque background under Reduce Transparency, heavier border and full-strength label colour under Increase Contrast. Every state has an SF Symbol and words; colour is applied last and carries nothing alone. Labels and hints on every control.
6. **Throttle.** ~16 ms coalescing inside `update(_:)` in the controller, not the view. Only `generating` is eligible; every other state renders at once and cancels the pending flush so a queued snapshot cannot overwrite a terminal result. Timer runs in `RunLoop.Mode.common`.
7. **Picker keys.** 1-5, up/down arrows, Return and keypad Enter, Escape. All through the same monitor. Digits and Return are gated on `plainKeystroke(_:)` so ⌘3 in the app underneath is not stolen.

## Concerns

1. **The global monitor cannot swallow the digit.** When the picker is up and the user presses `3`, we pick style 3 and the character also reaches the frontmost app. The only fix is making the panel key, which costs the selection and breaks the product, so this is the correct tradeoff, but it has a consequence for Task 5: **the coordinator should capture the selection before showing the picker**, so a stray keystroke cannot modify the text being rewritten. Documented in `Overlay/AGENTS.md`. The real fix, if it ever matters, is a `CGEventTap`, which needs its own permission.
2. **Height measurement is the part most likely to need a tweak on a real screen.** `NSHostingView.fittingSize` at a pinned 460pt width is the standard approach and I take `max(fittingSize, intrinsicContentSize)` to cover the case where SwiftUI has not settled, but a one-frame lag after a state change is possible. Symptom would be a panel slightly too short for one frame. The `NSScrollView` means nothing becomes unreachable if it happens. Worth a look during Task 5 integration.
3. **`update(from: RewriteEvent)` maps `.finished` to `.generating`, not to a terminal state,** because the engine finishing is not the transaction finishing: validation and replacement come after. The coordinator must push `.applying` and then `.success` / `.readOnly` / `.targetChanged` itself. If that is not what Task 5 wants, the method is three lines and easy to change.
4. **The panel never dismisses itself,** including from `success`. The coordinator owns the auto-dismiss delay. The monitors deliberately stay armed through terminal states so Escape still closes a result panel.
5. **Accessibility settings are sampled at `show()`, not observed.** A user who flips Reduce Motion mid-rewrite sees it on the next one. This was chosen to avoid a second observer with a lifetime to manage alongside the key monitors; the rationale is in `AGENTS.md` in case a future agent thinks it is an oversight.
