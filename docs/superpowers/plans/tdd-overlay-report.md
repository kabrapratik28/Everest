# Task 4 — Overlay, rebuilt test-first

**Status:** complete. 57 RED→GREEN cycles, 60 behaviour tests in 10 suites, all green.

Every behaviour below was driven by writing one test, running it, watching it fail, writing the least code to pass, and running it again. The RED and GREEN output is pasted verbatim. Where a compile error was the first RED and a behavioural failure was more informative, both are shown.

---

## A note on where the test output came from

The command in the brief is:

```bash
cd /Users/kabara/Desktop/Improve/EverestKit && swift test --filter <TestName>
```

That command is unusable for minutes at a stretch while four agents share one SwiftPM package, because **any** agent's in-flight RED test is a compile error that fails the whole build for everyone. Observed repeatedly, for example:

```
/Users/kabara/Desktop/Improve/EverestKit/Tests/RewriteCoreTests/CoreTests.swift:8:18: error: cannot find 'Preset' in scope
error: Build failed
```

```
/Users/kabara/Desktop/Improve/EverestKit/Tests/EnginesTests/MLXEngineTests.swift:11:68: error: cannot find type 'RewriteRequest' in scope
error: Build failed
```

```
/Users/kabara/Desktop/Improve/EverestKit/Package.swift:65:1: error: expected expression
```

So the per-behaviour cycles were run through an isolated SwiftPM package at `/tmp/overlay-tdd/` whose `Sources/Overlay`, `Sources/RewriteCore` and `Tests/OverlayTests` are **symlinks to the real EverestKit directories**. Same files, same compiler, same Swift 6 mode, same macOS 26 target; no MLX dependency and no other agent's test target, so an Overlay RED fails for Overlay reasons. Nothing was copied and nothing was mocked out.

The canonical command is re-run at the end of this report against the real package.

---

## Behaviour 1 — `PanelState` has eleven cases

The completeness of the case list is enforced by `PanelStateKind`, a payload-free mirror with `CaseIterable`. Adding a twelfth `PanelState` case forces a twelfth kind, which grows `allCases`, which fails this test until the new state is sampled.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:12:26: error: cannot find type 'PanelState' in scope
10 |     /// added without also adding a `PanelStateKind`, which makes this array
11 |     /// incomplete and fails the test below until a sample is supplied.
12 |     static let samples: [PanelState] = [
   |                          `- error: cannot find type 'PanelState' in scope
error: Build failed
```

**GREEN**
```
◇ Suite "PanelState" started.
◇ Test "covers exactly eleven kinds, one sample each" started.
✔ Test "covers exactly eleven kinds, one sample each" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 2 — every state returns a non-empty SF Symbol and non-empty words

One test iterating all eleven samples. `symbolName` and `title` are both a `switch` with no `default`, so the compiler demands the icon and the words for a new case, and this test demands they are not empty.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:38:28: error: value of type 'PanelState' has no member 'symbolName'
38 |             #expect(!state.symbolName.isEmpty, "\(state.kind) has no SF Symbol")
   |                            `- error: value of type 'PanelState' has no member 'symbolName'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:39:28: error: value of type 'PanelState' has no member 'title'
   |                            `- error: value of type 'PanelState' has no member 'title'
error: Build failed
```

**GREEN**
```
◇ Test "every state supplies both an SF Symbol and words, never colour alone" started.
✔ Test "covers exactly eleven kinds, one sample each" passed after 0.001 seconds.
✔ Test "every state supplies both an SF Symbol and words, never colour alone" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 3 — `heldForManualCopy` does not auto-dismiss, `success` does

Asserted per-state across all eleven, not just for the two named cases.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:60:36: error: value of type 'PanelState' has no member 'autoDismissAfter'
58 |
59 |         #expect(PanelState.heldForManualCopy(text: "rewritten", reason: "gone").autoDismissAfter == nil)
60 |         #expect(PanelState.success.autoDismissAfter != nil)
   |                                    `- error: value of type 'PanelState' has no member 'autoDismissAfter'
error: Build failed
```

**GREEN**
```
◇ Test "heldForManualCopy never auto-dismisses, success does" started.
✔ Test "every state supplies both an SF Symbol and words, never colour alone" passed after 0.001 seconds.
✔ Test "covers exactly eleven kinds, one sample each" passed after 0.001 seconds.
✔ Test "heldForManualCopy never auto-dismisses, success does" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 4 — panel frame: centred, near the bottom, 460pt wide

The test screen is at a **negative** origin on purpose. A frame computed from `width / 2` instead of `midX` passes on a screen at the origin and puts the panel off the side of a second display.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelGeometryTests.swift:14:21: error: cannot find 'PanelGeometry' in scope
12 |     @Test("panel is 460pt wide, horizontally centred, and sits near the bottom")
13 |     func bottomCentred() {
14 |         let frame = PanelGeometry.frame(contentHeight: 120, in: Self.screen)
   |                     `- error: cannot find 'PanelGeometry' in scope
error: Build failed
```

**GREEN**
```
Build complete! (1.50 sec)
◇ Suite "PanelGeometry" started.
◇ Test "panel is 460pt wide, horizontally centred, and sits near the bottom" started.
✔ Test "panel is 460pt wide, horizontally centred, and sits near the bottom" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 5a — height grows with content, capped at 40% of the visible screen

Tested below the cap, at the cap boundary, and well above it.

**RED** (behavioural — the height was following the content past the cap)
```
✘ Test "height follows the content up to 40% of the visible screen and no further" recorded an issue at PanelGeometryTests.swift:28:9: Expectation failed: PanelGeometry.frame(contentHeight: cap + 1, in: Self.screen).height == cap
↳ PanelGeometry.frame(contentHeight: cap + 1, in: Self.screen).height → 432.6
↳ cap → 431.6
✘ Test "height follows the content up to 40% of the visible screen and no further" recorded an issue at PanelGeometryTests.swift:29:9: Expectation failed: PanelGeometry.frame(contentHeight: 4000, in: Self.screen).height == cap
↳ PanelGeometry.frame(contentHeight: 4000, in: Self.screen).height → 4000.0
↳ cap → 431.6
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 2 issues.
```

**GREEN**
```
✔ Test "panel is 460pt wide, horizontally centred, and sits near the bottom" passed after 0.001 seconds.
✔ Test "height follows the content up to 40% of the visible screen and no further" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 5b — past the cap it scrolls

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelGeometryTests.swift:38:31: error: type 'PanelGeometry' has no member 'scrolls'
36 |         #expect(PanelGeometry.scrolls(contentHeight: cap - 1, in: Self.screen) == false)
37 |         #expect(PanelGeometry.scrolls(contentHeight: cap, in: Self.screen) == false)
38 |         #expect(PanelGeometry.scrolls(contentHeight: cap + 1, in: Self.screen) == true)
   |                               `- error: type 'PanelGeometry' has no member 'scrolls'
error: Build failed
```

**GREEN**
```
✔ Test "content taller than the cap scrolls instead of growing the window" passed after 0.001 seconds.
✔ Test "panel is 460pt wide, horizontally centred, and sits near the bottom" passed after 0.001 seconds.
✔ Test "height follows the content up to 40% of the visible screen and no further" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 6a — a burst coalesces to far fewer renders than updates

200 snapshots one millisecond apart, replayed against injected time.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/StreamCoalescerTests.swift:14:25: error: cannot find 'StreamCoalescer' in scope
13 |     func burstRendersFarFewerTimesThanItUpdates() {
14 |         var coalescer = StreamCoalescer()
   |                         `- error: cannot find 'StreamCoalescer' in scope
error: Build failed
```

**GREEN**
```
◇ Suite "StreamCoalescer" started.
◇ Test "a burst of streaming snapshots renders far fewer times than it updates" started.
✔ Test "a burst of streaming snapshots renders far fewer times than it updates" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

## Behaviour 6b — the last update is never dropped

This is the one that matters. The naive throttle from 6a was left in place and a stub `flush()` added so the **behavioural** failure was visible rather than just a compile error:

**RED (compile)**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/StreamCoalescerTests.swift:46:36: error: value of type 'StreamCoalescer' has no member 'flush'
46 |         if let flushed = coalescer.flush() { lastRendered = flushed }
   |                                    `- error: value of type 'StreamCoalescer' has no member 'flush'
```

**RED (behavioural — the naive throttle losing the last seven snapshots)**
```
✘ Test "the last snapshot in a burst is never dropped" recorded an issue at StreamCoalescerTests.swift:48:9: Expectation failed: lastRendered == .generating(text: "snapshot 199")
↳ lastRendered == .generating(text: "snapshot 199") → false
↳   lastRendered → .generating(text: "snapshot 192")
↳     some → .generating(text: "snapshot 192")
↳       generating → (text: "snapshot 192")
↳         text → "snapshot 192"
↳     some → .generating(text: "snapshot 199")
↳       generating → (text: "snapshot 199")
↳         text → "snapshot 199"
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

**GREEN**
```
✔ Test "the last snapshot in a burst is never dropped" passed after 0.001 seconds.
✔ Test "a burst of streaming snapshots renders far fewer times than it updates" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 6c — a terminal state renders at once and cancels the held snapshot

**RED**
```
✘ Test "a terminal state renders at once and cancels the snapshot waiting behind it" recorded an issue at StreamCoalescerTests.swift:61:9: Expectation failed: coalescer.accept(.success, at: Self.start + .milliseconds(2)) == .success
↳   coalescer.accept(.success, at: Self.start + .milliseconds(2)) → nil
↳     some → .success
✘ Test "a terminal state renders at once and cancels the snapshot waiting behind it" recorded an issue at StreamCoalescerTests.swift:62:9: Expectation failed: coalescer.flush() == nil
↳   coalescer.flush() → .success
✘ Test "a terminal state renders at once and cancels the snapshot waiting behind it" failed after 0.001 seconds with 2 issues.
```

**GREEN**
```
✔ Test "a terminal state renders at once and cancels the snapshot waiting behind it" passed after 0.001 seconds.
✔ Test "a burst of streaming snapshots renders far fewer times than it updates" passed after 0.001 seconds.
✔ Test "the last snapshot in a burst is never dropped" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 6d — the controller's `update` actually goes through the throttle

A coalescer nothing calls is dead code. This drives the `PanelClock` seam.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:49:24: error: cannot find type 'PanelClock' in scope
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:83:12: error: cannot find type 'PanelClock' in scope
error: Build failed
```

**GREEN**
```
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 11 tests in 1 suite passed after 0.001 seconds.
```

---

## Behaviour 7a — Escape cancels, from every state

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelKeyMapTests.swift:12:60: error: cannot find type 'Keystroke' in scope
11 |     /// here is deliberate: it would be wrong for the map to care.
12 |     static func digit(_ value: Int, plain: Bool = true) -> Keystroke {
   |                                                            `- error: cannot find type 'Keystroke' in scope
error: Build failed
```

**GREEN**
```
◇ Suite "PanelKeyMap" started.
◇ Test "Escape cancels from every state" started.
✔ Test "Escape cancels from every state" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

## Behaviour 7b — number keys 1 through 5 pick that style

**RED**
```
✘ Test "number keys 1 through 5 pick that style in the picker" recorded an issue at PanelKeyMapTests.swift:32:13: Expectation failed: PanelKeyMap.action(for: Self.digit(number), in: picker) == .pickStyle(index: number - 1)
↳   PanelKeyMap.action(for: Self.digit(number), in: picker) → nil
↳   .pickStyle(index: number - 1) → .pickStyle(index: 0)
```

**GREEN**
```
✔ Test "number keys 1 through 5 pick that style in the picker" passed after 0.001 seconds.
✔ Test "Escape cancels from every state" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7c — Return selects

**RED**
```
✘ Test "Return commits the highlighted style in the picker" recorded an issue at PanelKeyMapTests.swift:40:9: Expectation failed: PanelKeyMap.action(for: Self.enter, in: picker) == .commitHighlightedStyle
↳   PanelKeyMap.action(for: Self.enter, in: picker) → nil
↳     some → .commitHighlightedStyle
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

**GREEN**
```
✔ Test "Return commits the highlighted style in the picker" passed after 0.001 seconds.
✔ Test "Escape cancels from every state" passed after 0.001 seconds.
✔ Test "number keys 1 through 5 pick that style in the picker" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7d — the picker's keys do nothing outside the picker

The monitors are armed for the whole transaction, so this map sees every keystroke typed anywhere during a rewrite.

**RED**
```
✘ Test "the picker's keys do nothing when the picker is not up" recorded an issue at PanelKeyMapTests.swift:49:13: Expectation failed: PanelKeyMap.action(for: Self.digit(2), in: state) == nil
↳ .capturing
↳   PanelKeyMap.action(for: Self.digit(2), in: state) → .pickStyle(index: 1)
```

**GREEN**
```
✔ Test "Escape cancels from every state" passed after 0.001 seconds.
✔ Test "Return commits the highlighted style in the picker" passed after 0.001 seconds.
✔ Test "the picker's keys do nothing when the picker is not up" passed after 0.001 seconds.
✔ Test "number keys 1 through 5 pick that style in the picker" passed after 0.001 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7e — an out-of-range number does nothing

Covers `0`, `6`, `9`, a digit past the end of a three-item list, and `6` on a six-item list. The RED shows the naive version producing `.pickStyle(index: -1)`, which is a crash waiting at the subscript.

**RED**
```
✘ Test "a number outside the numbered rows does nothing" recorded an issue at PanelKeyMapTests.swift:64:9: Expectation failed: PanelKeyMap.action(for: Self.digit(0), in: five) == nil
↳   PanelKeyMap.action(for: Self.digit(0), in: five) → .pickStyle(index: -1)
✘ Test "a number outside the numbered rows does nothing" recorded an issue at PanelKeyMapTests.swift:65:9: Expectation failed: PanelKeyMap.action(for: Self.digit(6), in: five) == nil
↳   PanelKeyMap.action(for: Self.digit(6), in: five) → .pickStyle(index: 5)
✘ Test "a number outside the numbered rows does nothing" recorded an issue at PanelKeyMapTests.swift:66:9: Expectation failed: PanelKeyMap.action(for: Self.digit(9), in: five) == nil
↳   PanelKeyMap.action(for: Self.digit(9), in: five) → .pickStyle(index: 8)
```

**GREEN**
```
✔ Test "Escape cancels from every state" passed after 0.001 seconds.
✔ Test "Return commits the highlighted style in the picker" passed after 0.001 seconds.
✔ Test "number keys 1 through 5 pick that style in the picker" passed after 0.001 seconds.
✔ Test "a number outside the numbered rows does nothing" passed after 0.001 seconds.
✔ Test "the picker's keys do nothing when the picker is not up" passed after 0.001 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7f — a digit with a modifier held is left to the app underneath

**RED**
```
✘ Test "a digit with a modifier held is left to the app underneath" recorded an issue at PanelKeyMapTests.swift:78:9: Expectation failed: PanelKeyMap.action(for: Self.digit(3, plain: false), in: picker) == nil
↳   PanelKeyMap.action(for: Self.digit(3, plain: false), in: picker) → .pickStyle(index: 2)
```

**GREEN**
```
✔ Test "a digit with a modifier held is left to the app underneath" passed after 0.001 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7g — arrow keys move the highlight and stop at both ends

**RED (compile)**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelKeyMapTests.swift:9:55: error: type 'Keystroke' has no member 'upArrowKeyCode'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelKeyMapTests.swift:10:57: error: type 'Keystroke' has no member 'downArrowKeyCode'
```

**RED (behavioural)**
```
✘ Test "the arrow keys move the highlight and stop at both ends" recorded an issue at FloatingPanelControllerTests.swift:292:9: Expectation failed: controller.highlightedStyleIndex == 2
↳   controller.highlightedStyleIndex → 0
✘ Test "the arrow keys move the highlight and stop at both ends" recorded an issue at FloatingPanelControllerTests.swift:295:9: Expectation failed: controller.highlightedStyleIndex == 4
↳   controller.highlightedStyleIndex → 0
```

**GREEN**
```
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 13 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 7h — `NSEvent` → `Keystroke`

Testable headlessly: `NSEvent.keyEvent(with:…)` constructs without a window server. ⌘, ⌥, ⌃ and ⇧ all make a keystroke non-plain, and the character is read ignoring modifiers.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/KeystrokeFromEventTests.swift:33:27: error: missing argument label 'keyCode:' in call
/private/tmp/overlay-tdd/Tests/OverlayTests/KeystrokeFromEventTests.swift:33:27: error: missing arguments for parameters 'characters', 'isPlain' in call
error: Build failed
```

**GREEN**
```
◇ Test run started.
✔ Test "the character is taken ignoring modifiers" passed after 0.003 seconds.
✔ Test "only an unmodified key counts as plain" passed after 0.003 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.003 seconds.
```

---

## Behaviour 8a — the monitor is installed on show and removed on dismiss

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:7:28: error: cannot find type 'KeyMonitoring' in scope
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:40:26: error: cannot find 'FloatingPanelController' in scope
error: Build failed
```

**GREEN**
```
◇ Suite "FloatingPanelController" started.
◇ Test "the key monitor is installed on show and removed on dismiss" started.
✔ Test "the key monitor is installed on show and removed on dismiss" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

## Behaviour 8b — arming and disarming are idempotent

Arming twice would install four real `NSEvent` monitors and fire `onCancel` twice for one Escape.

**RED**
```
✘ Test "arming twice installs one monitor and disarming twice removes one" recorded an issue at FloatingPanelControllerTests.swift:62:9: Expectation failed: monitor.installs == 1
↳   monitor.installs → 2
✘ Test "arming twice installs one monitor and disarming twice removes one" recorded an issue at FloatingPanelControllerTests.swift:66:9: Expectation failed: monitor.removals == 1
↳   monitor.removals → 2
✘ Test "arming twice installs one monitor and disarming twice removes one" failed after 0.001 seconds with 2 issues.
```

**GREEN**
```
✔ Test "arming twice installs one monitor and disarming twice removes one" passed after 0.001 seconds.
✔ Test "the key monitor is installed on show and removed on dismiss" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

## Behaviour 8c — the error path leaves no monitor behind

`show` → `update(.error)` → `dismiss`, then a second transaction, asserting `installs == removals` throughout.

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:79:20: error: value of type 'FloatingPanelController' has no member 'update'
   |                    `- error: value of type 'FloatingPanelController' has no member 'update'
error: Build failed
```

**GREEN**
```
◇ Test "a transaction that ends in an error leaves no monitor behind" started.
✔ Test "the key monitor is installed on show and removed on dismiss" passed after 0.001 seconds.
✔ Test "a transaction that ends in an error leaves no monitor behind" passed after 0.001 seconds.
✔ Test "arming twice installs one monitor and disarming twice removes one" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

---

## The rest of the required API

### `onCancel` fires on Escape, and stops after dismiss

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:96:20: error: value of type 'FloatingPanelController' has no member 'onCancel'
error: Build failed
```

**GREEN**
```
✔ Test "Escape delivered by the monitor fires onCancel, and stops doing so after dismiss" passed after 0.001 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

### `onPickStyle` fires with that row's preset

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:112:20: error: value of type 'FloatingPanelController' has no member 'onPickStyle'
error: Build failed
```

**GREEN**
```
✔ Test "a number key in the picker fires onPickStyle with that row's preset" passed after 0.001 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

### Return picks the highlighted row, which starts on the first style

**RED**
```
✘ Test "Return picks the highlighted row, which starts on the first style" recorded an issue at FloatingPanelControllerTests.swift:276:9: Expectation failed: picked.value == PanelKeyMapTests.fiveStyles[0]
↳   picked.value → nil
↳   PanelKeyMapTests.fiveStyles[0] → Preset(id: 003FCD72-…, name: "Style 1", subtitle: "sub 1", instruction: "do 1")
```

**GREEN**
```
✔ Test run with 12 tests in 1 suite passed after 0.001 seconds.
```

### A new picker starts on the first row again

**RED**
```
✘ Test "a new picker starts on the first row again" recorded an issue at FloatingPanelControllerTests.swift:310:9: Expectation failed: controller.highlightedStyleIndex == 0
↳   controller.highlightedStyleIndex → 2
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
```

**GREEN**
```
✔ Test run with 37 tests in 7 suites passed after 0.003 seconds.
```

### Clicking a row picks that style; an index outside the list does nothing

A click does not go through `PanelKeyMap`, so it needs its own bounds check.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Sources/Overlay/FloatingPanelController+Live.swift:22:72: error: 'pickStyle' is inaccessible due to 'private' protection level
error: Build failed
```

**GREEN**
```
✔ Test "picking a row directly fires onPickStyle, and an index outside the list does nothing" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

### Moving the highlight redraws the picker with the new row marked

An arrow key that moves an index nobody draws is an invisible cursor.

**RED**
```
✘ Test "moving the highlight redraws the picker with the new row marked" recorded an issue at FloatingPanelControllerTests.swift:332:9: Expectation failed: surface.presentedHighlights.last == 1
↳   surface.presentedHighlights.last → 0
✘ Test "moving the highlight redraws the picker with the new row marked" failed after 0.001 seconds with 1 issue.
```

**GREEN**
```
✔ Test run with 40 tests in 7 suites passed after 0.004 seconds.
```

### `copyableText` — only the states holding a finished rewrite

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:71:36: error: value of type 'PanelState' has no member 'copyableText'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:75:81: error: value of type 'PanelState' has no member 'copyableText'
error: Build failed
```

**GREEN**
```
✔ Test "only the states holding a finished rewrite offer text to copy" passed after 0.001 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

### `bodyText` — which states show the rewrite itself

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:88:28: error: value of type 'PanelState' has no member 'bodyText'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:91:59: error: value of type 'PanelState' has no member 'bodyText'
```

**GREEN**
```
✔ Test "the rewrite is shown while streaming and in every state that is holding one" passed after 0.001 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.001 seconds.
```

### `onCopy` fires with the held rewrite, and is silent mid-stream

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:125:20: error: value of type 'FloatingPanelController' has no member 'onCopy'
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:128:20: error: value of type 'FloatingPanelController' has no member 'copy'
error: Build failed
```

**GREEN**
```
✔ Test "copy hands over the held rewrite, and does nothing mid-stream" passed after 0.001 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.001 seconds.
```

### The panel is placed by `PanelGeometry` (drives the `PanelSurface` seam)

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:8:25: error: cannot find type 'PanelSurface' in scope
error: Build failed
```

**GREEN**
```
✔ Test "the panel is placed by PanelGeometry on the screen it was handed" passed after 0.001 seconds.
✔ Test run with 7 tests in 1 suite passed after 0.001 seconds.
```

### `update` redraws at the new content height

**RED**
```
✘ Test "update redraws the panel at the new state's content height" recorded an issue at FloatingPanelControllerTests.swift:210:9: Expectation failed: surface.presented.count == 2
↳   surface.presented.count → 1
✘ Test "update redraws the panel at the new state's content height" recorded an issue at FloatingPanelControllerTests.swift:211:9: Expectation failed: surface.presented.last?.state == .generating(text: "The quick brown fox")
↳   surface.presented.last?.state → .capturing
```

**GREEN**
```
✔ Test run with 8 tests in 1 suite passed after 0.001 seconds.
```

### The screen is captured at show, so a growing panel cannot hop displays

The RED shows the panel jumping to x = 4270 on a second display because the pointer moved mid-stream.

**RED**
```
✘ Test "the screen is captured at show, so a growing panel cannot hop displays" recorded an issue at FloatingPanelControllerTests.swift:240:9: Expectation failed: surface.presented.last?.frame == PanelGeometry.frame(contentHeight: 300, in: first)
↳   surface.presented.last?.frame → (4270.0, 96.0, 460.0, 300.0)
↳   PanelGeometry.frame(contentHeight: 300, in: first) → (634.0, 96.0, 460.0, 300.0)
```

**GREEN**
```
◇ Test run started.
✔ Test run with 9 tests in 1 suite passed after 0.001 seconds.
```

### `dismiss` takes the panel off screen, once

**RED**
```
✘ Test "dismiss takes the panel off screen, once" recorded an issue at FloatingPanelControllerTests.swift:254:9: Expectation failed: surface.hides == 1
↳   surface.hides → 0
```

**GREEN**
```
✔ Test run with 10 tests in 1 suite passed after 0.001 seconds.
```

### The accessibility settings are re-read once per presentation

**RED**
```
✘ Test "the accessibility settings are re-read once per presentation, not per update" recorded an issue at FloatingPanelControllerTests.swift:317:9: Expectation failed: surface.appearanceRefreshes == 1
↳   surface.appearanceRefreshes → 0
✘ Test "the accessibility settings are re-read once per presentation, not per update" recorded an issue at FloatingPanelControllerTests.swift:321:9: Expectation failed: surface.appearanceRefreshes == 1
↳   surface.appearanceRefreshes → 0
```

**GREEN**
```
✔ Test run with 41 tests in 7 suites passed after 0.004 seconds.
```

### `PanelState(RewriteEvent)` and `update(from:)`

**RED (mapping)**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateFromEventTests.swift:11:17: error: 'PanelState' cannot be constructed because it has no accessible initializers
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateFromEventTests.swift:12:17: error: 'PanelState' cannot be constructed because it has no accessible initializers
```

**GREEN (mapping)**
```
✔ Test "each engine event maps to the panel state that describes it" passed after 0.001 seconds.
✔ Test "a finished stream says the app is applying the result, not that it is done" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

**RED (`update(from:)` goes through the same throttle)**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:415:30: error: extraneous argument label 'from:' in call
/private/tmp/overlay-tdd/Tests/OverlayTests/FloatingPanelControllerTests.swift:415:38: error: type 'PanelState' has no member 'outputSnapshot'
error: Build failed
```

**GREEN**
```
✔ Test run with 44 tests in 8 suites passed after 0.004 seconds.
```

---

## Accessibility settings

### Reduce Motion removes the transition

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:6:24: error: cannot find 'PanelAppearance' in scope
error: Build failed
```

**GREEN**
```
◇ Test run started.
✔ Test "Reduce Motion removes the transition between states" passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
```

### Reduce Motion suppresses indeterminate spinners but keeps a determinate bar

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:29:28: error: value of type 'PanelAppearance' has no member 'progressStyle'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:30:25: error: value of type 'PanelAppearance' has no member 'progressStyle'
```

**GREEN**
```
✔ Test "Reduce Motion removes the transition between states" passed after 0.001 seconds.
✔ Test "Reduce Motion suppresses indeterminate spinners but keeps a determinate bar" passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
```

### Reduce Transparency swaps the blur material for an opaque background

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:49:28: error: value of type 'PanelAppearance' has no member 'usesTranslucentMaterial'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:50:25: error: value of type 'PanelAppearance' has no member 'usesTranslucentMaterial'
```

**GREEN**
```
✔ Test "Reduce Transparency swaps the blur material for an opaque background" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
```

### Increase Contrast thickens the border and drops decorative colour

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:62:26: error: value of type 'PanelAppearance' has no member 'borderWidth'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelAppearanceTests.swift:62:51: error: value of type 'PanelAppearance' has no member 'borderWidth'
```

**GREEN**
```
✔ Test "Reduce Motion suppresses indeterminate spinners but keeps a determinate bar" passed after 0.001 seconds.
✔ Test "Reduce Transparency swaps the blur material for an opaque background" passed after 0.001 seconds.
✔ Test "Reduce Motion removes the transition between states" passed after 0.001 seconds.
✔ Test "Increase Contrast thickens the border and drops decorative colour" passed after 0.001 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

### The spoken value never carries the streaming text — but does carry the reason

**RED**
```
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:85:28: error: value of type 'PanelState' has no member 'accessibilityValue'
/private/tmp/overlay-tdd/Tests/OverlayTests/PanelStateTests.swift:89:27: error: value of type 'PanelState' has no member 'accessibilityValue'
```

**GREEN**
```
✔ Test "the panel's spoken value says what is happening and never carries the streaming text" passed after 0.001 seconds.
✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
```

---

## Round two: the six additional requirements

Seven further cycles. Run with the isolation command from the team lead's note — `swift build --target OverlayTests && xcrun xctest .build/out/Products/Debug/OverlayTests.xctest` — against the real package.

### Monitor teardown must be structural, not disciplinary

Install-on-show / remove-on-dismiss was too weak. The new requirement is that no reachable state has the monitors installed with the handle to remove them lost. Dropping the controller mid-rewrite is that state.

**RED** — a leaked global key monitor, exactly the failure the guard exists for:
```
◇ Test "releasing the controller with a panel still up removes the monitors" started.
✘ Test "releasing the controller with a panel still up removes the monitors" recorded an issue at FloatingPanelControllerTests.swift:181:9: Expectation failed: monitor.removals == 1
↳ monitor.removals == 1 → false
↳   monitor.removals → 0
✘ Test "releasing the controller with a panel still up removes the monitors" recorded an issue at FloatingPanelControllerTests.swift:182:9: Expectation failed: monitor.isInstalled == false
↳ monitor.isInstalled == false → false
↳   monitor.isInstalled → true
✘ Test "releasing the controller with a panel still up removes the monitors" failed after 0.001 seconds with 2 issues.
```

`KeyMonitoring.install` now returns a `KeyMonitorHandle` whose `isolated deinit` removes the monitors, and the controller holds the only reference. `remove()` is gone from the protocol: clearing the reference *is* the removal, and releasing the controller does the same. There is no call left to forget.

**GREEN**
```
Build complete! (2.88 sec)
✔ Test run with 46 tests in 9 suites passed after 0.006 seconds.
```

### Content past the cap scrolls — frame stops growing, content stays reachable

Capping the window is half the job; if the layout also forgets how tall the content was, the overflow is clipped rather than scrollable.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelGeometryTests.swift:49:35: error: type 'PanelGeometry' has no member 'layout'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelGeometryTests.swift:54:34: error: type 'PanelGeometry' has no member 'layout'
```

**GREEN**
```
◇ Test "past the cap the frame stops growing and the full content stays reachable" started.
✔ Test "past the cap the frame stops growing and the full content stays reachable" passed after 0.001 seconds.
✔ Test run with 47 tests in 9 suites passed after 0.011 seconds.
```

### Geometry stays sane and on-screen on a small display

**RED** — the panel hung off the bottom of a short screen and off the left edge of a narrow one:
```
✘ Test "the panel fits entirely inside a small visible frame" recorded an issue at PanelGeometryTests.swift:74:13: Expectation failed: screen.contains(layout.frame)
↳ (0.0, 0.0, 1280.0, 150.0) does not contain (410.0, 96.0, 460.0, 60.0)
✘ Test "the panel fits entirely inside a small visible frame" recorded an issue at PanelGeometryTests.swift:74:13: Expectation failed: screen.contains(layout.frame)
↳ (0.0, 0.0, 400.0, 240.0) does not contain (-30.0, 96.0, 460.0, 96.0)
✘ Test "the panel fits entirely inside a small visible frame" failed after 0.001 seconds with 2 issues.
```

**GREEN**
```
◇ Test "the panel fits entirely inside a small visible frame" started.
✔ Test "the panel fits entirely inside a small visible frame" passed after 0.001 seconds.
✔ Test run with 48 tests in 9 suites passed after 0.007 seconds.
```

### A long unbroken token wraps inside the body width

Measured with the same text engine SwiftUI uses underneath, at exactly the width `PanelGeometry.bodyWidth` gives the body — so if someone changes the padding or the width and a URL stops fitting, this fires.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/LongTextLayoutTests.swift:30:39: error: type 'PanelGeometry' has no member 'bodyWidth'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/LongTextLayoutTests.swift:43:31: error: type 'PanelGeometry' has no member 'bodyWidth'
```

**GREEN** — and the panel width is asserted invariant across content heights from 0 to 4000:
```
◇ Test "a long unbroken token wraps inside the body width instead of overflowing it" started.
✔ Test "a long unbroken token wraps inside the body width instead of overflowing it" passed after 0.028 seconds.
◇ Test "the body width fits inside the panel, and the panel never widens for its content" started.
✔ Test "the body width fits inside the panel, and the panel never widens for its content" passed after 0.001 seconds.
✔ Test run with 50 tests in 10 suites passed after 0.036 seconds.
```

`RewriteView` now pads by `PanelGeometry.contentPadding`, the same number `bodyWidth` subtracts, so the width tested is the width drawn.

### The panel appears on the screen containing the pointer

The placement was already a pure function of a `CGRect` and already tested on a negative-origin screen. What was *not* tested was the choosing, which lived as a force-unwrapped chain in the live factory — exactly where a multi-monitor bug hides.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelGeometryTests.swift:88:31: error: type 'PanelGeometry' has no member 'screen'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelGeometryTests.swift:89:31: error: type 'PanelGeometry' has no member 'screen'
```

**GREEN**
```
◇ Test "the screen chosen is the one containing the pointer" started.
✔ Test "the screen chosen is the one containing the pointer" passed after 0.001 seconds.
✔ Test run with 51 tests in 10 suites passed after 0.060 seconds.
```

`FloatingPanelController.live()` now supplies rectangles and lets the tested function choose; the `NSScreen.main!` force unwrap is gone.

### Streaming follows the tail until the user takes over

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:431:28: error: value of type 'FloatingPanelController' has no member 'followsTail'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:432:41: error: value of tuple type '(state: PanelState, frame: CGRect, scrolls: Bool)' has no member 'followsTail'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:434:20: error: value of type 'FloatingPanelController' has no member 'userScrolled'
```

**GREEN** — follows by default, stops after a user scroll, resumes at the bottom, and a fresh panel follows again:
```
◇ Test "streaming follows the tail until the user scrolls away, and resumes at the bottom" started.
✔ Test "streaming follows the tail until the user scrolls away, and resumes at the bottom" passed after 0.001 seconds.
✔ Test run with 52 tests in 10 suites passed after 0.037 seconds.
```

### `.finished` is not a terminal state

Already satisfied before this round, and tested: `PanelState(.finished(…)) == .applying`. Generation stopping is not the transaction succeeding — validation and replacement still follow and can still fail, and showing the finished text with no activity would make a working replacement look like a hang. The coordinator drives the terminal state.

### Refactors, still green

- **Seams consolidated.** `KeyMonitoring.swift`, `PanelClock.swift` and `PanelSurface.swift` merged into `Seams.swift`. Live implementations left in their own files.
- **YAGNI sweep.** `PanelGeometry.frame` and `PanelGeometry.scrolls` became test-only wrappers around `layout` once the controller moved over, so both were deleted and their callers migrated. `contentPastTheCapScrolls` was deleted as redundant with `overflowScrollsRatherThanBeingClipped` — same root cause, one signal. Test count went 52 → 51 as a result.

```
Build complete! (0.81 sec)
✔ Test run with 51 tests in 10 suites passed after 0.033 seconds.
```

### Views render

The team lead's `ScreenshotGenerator` runs against the finished views without modification — the `RewriteView(state:appearance:highlightedStyleIndex:onCopy:onPickStyle:)` signature it uses is unchanged:

```
✔ Test run with 51 tests in 10 suites passed after 0.240 seconds.
=== wrote 14 screenshots to /Users/kabara/Desktop/Everest-UI ===
  01-streaming-short.png  1056x317
  02-streaming-long.png  1056x477
  03-streaming-long-url.png  1056x381
  ...
  14-accessible-contrast.png  1056x477
```

`03-streaming-long-url.png` confirms visually what `LongTextLayoutTests` asserts: the URL breaks mid-token inside the panel rather than widening or clipping it.

---

## Round three: keyboard-driven panel

Five more cycles.

### The panel may take key status only in a terminal state

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelStateTests.swift:112:27: error: value of type 'PanelState' has no member 'acceptsKeyWindow'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelStateTests.swift:117:36: error: value of type 'PanelState' has no member 'acceptsKeyWindow'
```

**GREEN** — asserted across all eleven states, so a twelfth cannot quietly opt in:
```
◇ Test "only a terminal state that needs the user may take key status" started.
✔ Test "only a terminal state that needs the user may take key status" passed after 0.001 seconds.
✔ Test run with 52 tests in 10 suites passed after 0.036 seconds.
```

### The surface is told, per state, whether to accept key status

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:434:41: error: value of tuple type '(state: PanelState, layout: PanelLayout, followsTail: Bool)' has no member 'acceptsKey'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:438:41: error: value of tuple type '(state: PanelState, layout: PanelLayout, followsTail: Bool)' has no member 'acceptsKey'
```

**GREEN**
```
◇ Test "the surface is told, per state, whether the panel may take key status" started.
✔ Test "the surface is told, per state, whether the panel may take key status" passed after 0.001 seconds.
✔ Test run with 53 tests in 10 suites passed after 0.039 seconds.
```

`NonActivatingPanel.canBecomeKey` now returns a per-state flag instead of a constant `false`.

### ⌘C copies where there is a rewrite, and nowhere else

`Keystroke.isPlain` became `Keystroke.modifiers`, an `OptionSet`, because "no modifiers" and "exactly ⌘" are different questions and one Bool cannot answer both.

**RED (compile)**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelKeyMapTests.swift:94:80: error: type 'PanelKeyAction?' has no member 'copy'
```

**RED (behavioural, after adding the case)** — the compiler also forced a `case .copy` into the controller's exhaustive switch, which was left as `break` so the next cycle's test could drive it:
```
✘ Test "Command-C copies in the states holding a rewrite, and nowhere else" recorded an issue at PanelKeyMapTests.swift:95:13: Expectation failed: PanelKeyMap.action(for: Self.commandC, in: state) == expected
↳ .readOnly
↳   PanelKeyMap.action(for: Self.commandC, in: state) → nil
↳   expected → .copy
✘ Test "Command-C copies in the states holding a rewrite, and nowhere else" recorded an issue at PanelKeyMapTests.swift:95:13: Expectation failed: PanelKeyMap.action(for: Self.commandC, in: state) == expected
↳ .targetChanged
↳   PanelKeyMap.action(for: Self.commandC, in: state) → nil
↳   expected → .copy
```

**GREEN**
```
◇ Test "Command-C copies in the states holding a rewrite, and nowhere else" started.
✔ Test "Command-C copies in the states holding a rewrite, and nowhere else" passed after 0.001 seconds.
◇ Test "an unmodified C does not copy" started.
✔ Test "an unmodified C does not copy" passed after 0.001 seconds.
✔ Test run with 55 tests in 10 suites passed after 0.048 seconds.
```

### ⌘C is consumed in a key terminal state, and Escape never claims to be

The monitor handler now returns `Bool`; the local `NSEvent` monitor turns `true` into `nil` and swallows the event. The rule is `handle` returns `state.acceptsKeyWindow`: acting on a key is not the same as swallowing it, and a non-key panel claiming consumption would make the local monitor eat something the frontmost app should see.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:437:57: error: binary operator '==' cannot be applied to operands of type '()' and 'Bool'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:441:57: error: binary operator '==' cannot be applied to operands of type '()' and 'Bool'
```

**GREEN**
```
◇ Test "Command-C copies and is consumed in a key terminal state, and does nothing before one" started.
✔ Test "Command-C copies and is consumed in a key terminal state, and does nothing before one" passed after 0.001 seconds.
✔ Test run with 57 tests in 10 suites passed after 0.037 seconds.
```

### Every state that can be acted on shows the keystroke that does it

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelStateTests.swift:136:30: error: value of type 'PanelState' has no member 'keyHints'
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelStateTests.swift:136:43: error: cannot infer key path type from context; consider explicitly specifying a root type
```

**GREEN** — asserted per state against explicit kind sets, so a twelfth state with a copy action cannot ship without a hint:
```
◇ Test "every state that can be acted on shows the keystroke that does it" started.
✔ Test "every state that can be acted on shows the keystroke that does it" passed after 0.001 seconds.
✔ Test run with 58 tests in 10 suites passed after 0.039 seconds.
```

Rendered as keycap badges in `RewriteView`, secondary colour inside a bordered capsule, `.accessibilityHidden(true)` so VoiceOver does not read "Copy command C" as a label. Verified in the regenerated screenshots: `10-held-for-manual-copy.png` shows `⌘C Copy` and `esc Cancel`; `01-streaming-short.png` shows `esc Cancel` alone. The Copy button became icon-only, because with the badge row present the word appeared twice in a 460pt panel; it is still clickable and still carries its accessibility label.

### Return: not added, and the picker's Return kept

No Return-as-primary-action binding was ever written, so there was nothing to delete. The picker's existing Return binding — commit the highlighted style — is a different key in a different state, is required by the original Task 4 brief, and is kept.

### Not done: the `ProgressView` render override

Skipped deliberately, as offered. Exposing a render hook on `progressStyle` would add production surface whose only caller is a screenshot tool, which §1 rules out. The `reduceMotion: true` workaround already produces an honest still, since `progressStyle` genuinely returns `.hidden` under that setting — the screenshot shows what a Reduce Motion user really sees rather than a fabrication.

---

## Round four: the hint row becomes the control, and the scroll observer lands

Three cycles.

### Each hint carries the action it performs

The hint row is now the button, which only works if a hint knows what it *does*. Matching on the displayed words would break the first time someone rewords a label, so `KeyHint` carries a `PanelKeyAction` — the same vocabulary the key map produces, so mouse and keyboard share one set of actions.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelStateTests.swift:153:47: error: binary operator '==' cannot be applied to two '[T]' operands
```

**GREEN**
```
◇ Test "each hint carries the action it performs" started.
✔ Test "each hint carries the action it performs" passed after 0.001 seconds.
✔ Test run with 59 tests in 10 suites passed after 0.050 seconds.
```

### `cancel()` reaches the same place Escape does

The `esc Cancel` row is clickable and a click does not go through the key map, so both routes have to converge or the mouse and the keyboard drift apart. `handle`'s `.cancel` case now calls `cancel()` rather than firing `onCancel` directly, so there is one path.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/FloatingPanelControllerTests.swift:473:20: error: value of type 'FloatingPanelController' has no member 'cancel'
```

**GREEN**
```
◇ Test "cancel fires onCancel, the same as Escape does" started.
✔ Test "cancel fires onCancel, the same as Escape does" passed after 0.001 seconds.
✔ Test run with 60 tests in 10 suites passed after 0.036 seconds.
```

### "At the bottom" is a tolerance, not an equality

The part of the scroll wiring that is a *decision* rather than AppKit plumbing, and the place an off-by-one would hide. Scroll offsets are fractional, so a strict comparison means tail-following switches off on the first gesture and never resumes. Content shorter than the window counts as at the bottom, or following would be off for every short rewrite.

**RED**
```
/Users/kabara/Desktop/Improve/EverestKit/Tests/OverlayTests/PanelGeometryTests.swift:77:31: error: type 'PanelGeometry' has no member 'isScrolledToBottom'
```

**GREEN**
```
◇ Test "at the bottom is a tolerance, not an equality" started.
✔ Test "at the bottom is a tolerance, not an equality" passed after 0.001 seconds.
✔ Test run with 61 tests in 10 suites passed after 0.040 seconds.
```

### The view change, and concern 6 closed

The standalone icon button is deleted. `RewriteView` renders each hint as a plain-styled `Button` whose label is the keycap plus the words, dispatching through `hint.performs`; the badges stay `.accessibilityHidden(true)` and the row carries the real accessibility label. Verified in the regenerated screenshots: `10-held-for-manual-copy.png` now shows only `⌘C Copy` and `esc Cancel`, bottom-right, with no orphaned glyph.

`NSPanelSurface` now observes `NSView.boundsDidChangeNotification` on the clip view (with `postsBoundsChangedNotifications = true`, without which it silently never fires) and reports `PanelGeometry.isScrolledToBottom(...)` through `onScroll`, which `FloatingPanelController.live()` wires to `userScrolled(isAtBottom:)`. The observer token is held in a `KeyMonitorHandle`, so releasing the surface unregisters it and there is no reachable state where it is registered with nothing holding the means to remove it.

I reused `KeyMonitorHandle` rather than renaming it to something neutral like `TeardownHandle`: the rename is the better name, but `Tests/AppCoreTests/Harness.swift` references the type, and that file is outside this target's scope. Flagged for Task 5 rather than changed unilaterally.

---

## Final verification, canonical command, real package

Once the other agents' targets compiled, the command from the brief was run against the real `EverestKit` package:

```bash
cd /Users/kabara/Desktop/Improve/EverestKit && swift test --filter OverlayTests
```

```
Build complete! (3.27 sec)
✔ Suite ScreenshotGenerator passed after 0.001 seconds.
✔ Suite "PanelAppearance" passed after 0.001 seconds.
✔ Suite "StreamCoalescer" passed after 0.001 seconds.
✔ Suite "PanelGeometry" passed after 0.001 seconds.
✔ Suite "PanelState" passed after 0.001 seconds.
✔ Suite "PanelState from RewriteEvent" passed after 0.001 seconds.
✔ Suite "PanelKeyMap" passed after 0.001 seconds.
✔ Suite "FloatingPanelController" passed after 0.002 seconds.
✔ Suite "Keystroke from NSEvent" passed after 0.003 seconds.
✔ Suite "Long text layout" passed after 0.034 seconds.
✔ Test run with 61 tests in 10 suites passed after 0.047 seconds.
```

60 of those are Overlay behaviour tests; the 61st is the team lead's `ScreenshotGenerator`, which is skipped unless `EVEREST_SCREENSHOTS=1`.

The whole target, including the AppKit and SwiftUI files, builds clean under Swift 6 strict concurrency in the real package.

---

## What is integration-only, and why

Stated out loud per repo-root `AGENTS.md` §0, rather than assumed. Five files have no tests:

| File | Why not | What *is* tested instead |
|---|---|---|
| `NSPanelSurface.swift` | Creating an `NSPanel`, ordering it front without activating, and measuring an `NSHostingView` need a window server and a second application to point at. | Everything it is told — state, frame, scroll flag, highlighted row, when to refresh appearance — asserted against `SpySurface`. |
| `NSEventKeyMonitor.swift` | A real global `NSEvent` monitor needs a logged-in session and Accessibility permission. | The install/remove balance on four paths — including the error path and controller deallocation — asserted against `SpyKeyMonitor`. |
| `RunLoopPanelClock.swift` | A real `Timer` on a real run loop. | Every scheduling decision asserted against `FakeClock`, including that a held snapshot always gets a flush scheduled. |
| `PanelAppearance+NSWorkspace.swift` | Three property reads off `NSWorkspace`. | Every consequence of those three booleans. |
| `RewriteView.swift`, `StylePickerView.swift` | SwiftUI bodies. | They contain no decisions: every string, symbol, colour rule and progress style is read off a tested value. |

`Keystroke+NSEvent.swift` looked like it belonged on this list and does not: `NSEvent.keyEvent(with:…)` constructs headlessly, so the modifier and character rules are tested for real.

These five need a hand check once Task 5 exists: that the panel appears without stealing focus from a second app, that Escape closes it from that second app, that a long rewrite scrolls rather than growing, and that the panel is readable with Reduce Transparency on.

## Concerns

1. **The two `.onKeyPress`-shaped traps are still one careless edit away.** The panel's non-activation and the event monitors are load-bearing and are asserted only indirectly — `SpyKeyMonitor` proves the *balance*, not that a real global monitor was ever installed, and nothing in a unit test can prove the real panel does not activate. Both are documented at the top of `Sources/Overlay/AGENTS.md`; neither has a test that would catch a regression.

2. **`PanelState.detail` is the one presentation property with no test of its own.** It is exercised through `accessibilityValue`, which asserts that the `error` reason is spoken, but the per-state `detail` strings themselves are not pinned the way `symbolName` and `title` are.

3. **Auto-dismiss is decided but not wired.** `PanelState.autoDismissAfter` is tested per-state, and `heldForManualCopy` returning `nil` is enforced. Nothing in `FloatingPanelController` yet *acts* on it — no timer starts on `success`. That is a deliberate boundary: whoever owns the transaction (Task 5's `RewriteCoordinator`) should decide when the panel goes away, and it already has `PanelClock`-shaped machinery available. Worth confirming Task 5 picks it up, because the value existing and nothing reading it is exactly the kind of gap that survives a review.

4. **Four agents sharing one SwiftPM package made the prescribed command unusable for long stretches.** Every agent's RED is a build failure for every other agent. If this repo runs parallel TDD again, give each target its own package or each agent its own worktree; the symlinked harness at `/tmp/overlay-tdd/` and the later `swift build --target OverlayTests` + `xcrun xctest` both worked, but they are workarounds.

5. **`Sources/RewriteCore/_Placeholder.swift` is still there.** Overlay's was deleted the moment real source landed, as its own comment instructed. The other target is not mine to clean up.

6. **Tail-following is decided and wired but only half-observable.** `followsTail` is tested end to end through the controller and the surface spy, but nobody calls `userScrolled(isAtBottom:)` yet — the real `NSScrollView` needs a `boundsDidChangeNotification` observer in `NSPanelSurface` to report the scroll position back. That observer is an integration detail and, more to the point, it is another observer whose lifetime needs managing on the same paths as the key monitors, which is the thing this directory has been careful about. Whoever wires it should give it the same handle treatment rather than a bare `addObserver`.
