# Overlay: the floating panel

The window the user actually sees: a borderless panel that appears at the bottom of the screen, streams the rewrite into view, and goes away. Four files.

| File | What it is |
|---|---|
| `PanelState.swift` | The ten things the panel can be showing, plus how each one is spoken and drawn. |
| `FloatingPanelController.swift` | The window, its geometry, the key monitors, the streaming throttle. The only file here that knows AppKit exists. |
| `RewriteView.swift` | The SwiftUI content, the accessibility snapshot, the panel background. |
| `StylePickerView.swift` | The numbered list behind ⌘⇧I. |

The API the coordinator uses is `show(_:)`, `update(_:)`, `dismiss()`, and the two callbacks `onCancel` and `onPickStyle`. There is also `update(from: RewriteEvent)` as a convenience so the mapping from engine events to panel states is written once.

Almost everything below is a decision that looks removable and is not. This directory is small enough to read in ten minutes and subtle enough to break in one.

---

## The panel must not activate, and that is the whole product

`FloatingPanelController` builds an `NSPanel` with `.nonactivatingPanel` in its style mask. Not an `NSWindow`. Not an `NSPanel` without that flag.

Here is the exact failure if you change it. The user selects a sentence in Mail and presses ⌘I. A normal window ordering front activates this application. Mail resigns active. The moment Mail stops being the active application its selection stops being a live selection, and the accessibility element that used to report `AXSelectedText` now reports an empty string or a stale range. The capture in `Improve/Selection/` returns `noSelection`, or worse it returns the correct text and then `Improve/Replacement/` fails its frontmost check and downgrades to `copiedOnly`. Either way the app silently stops doing the one thing it exists to do, and it does it with no crash, no error in the log, and no failing test. Someone will spend an afternoon on it.

This is also why the panel sets `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, and `isExcludedFromWindowsMenu = true`, and why it is ordered on screen with `orderFrontRegardless()` rather than `orderFront(_:)` or `makeKeyAndOrderFront(_:)`. An inactive application's `orderFront(_:)` can be deferred until the app is next activated, which shows the panel at the wrong moment or not at all. `makeKeyAndOrderFront(_:)` reintroduces the activation problem through the back door.

`.borderless` is in the style mask for the same family of reasons and not only to hide the titlebar. A titled window can become key. A borderless one cannot without extra work, so the style mask is itself part of the guard.

## A non-activating panel receives no key events, so Escape comes from an event monitor

Follow the consequence through. The panel is never the key window. Nothing inside it is ever first responder. Therefore:

- `.onKeyPress(.escape)` never fires.
- `.keyboardShortcut(.cancelAction)` never fires.
- `@FocusState` never becomes true.
- `List(selection:)` never moves with the arrow keys.
- `cancelOperation(_:)` is never sent, because there is no responder chain to send it down.

Every one of these will look correct in an Xcode preview, where the preview host *is* key, and then do nothing at all in the shipped app. If you find yourself writing any of them in this directory, stop.

Keyboard input arrives through `KeyMonitorPair`, which installs two `NSEvent` monitors:

- The **global** monitor fires while another application is frontmost. That is the normal case here. A global monitor is an observer and cannot consume the event.
- The **local** monitor fires when this application is frontmost, which happens when the user has Settings open or has just clicked the status item. Global monitors never see your own process's events, so without the local one Escape would be dead in exactly the case where the user is looking straight at the app.

### The monitors must come down, and the design makes that automatic

A global key-down monitor sees every keystroke the user types in every application, for as long as it is installed. Passwords typed into other apps, messages, everything. It is the most sensitive thing this app ever touches, and the app has no business holding one except during the two or three seconds a rewrite is on screen.

So the guard is not "remember to call `removeMonitor` on every exit path". The monitors are wrapped in a small class whose `deinit` removes them, and the controller holds exactly one optional reference to it. `stopKeyMonitor()` assigns `nil`, ARC runs the `deinit`, the monitors are gone. If the controller itself is ever released with a panel still up, the same `deinit` still runs. There is no reachable state where the monitors are installed and the handle to them has been lost.

`dismiss()` calls `stopKeyMonitor()` as its first statement and has no early return, so every path out of a transaction disarms the monitors. `startKeyMonitor()` is idempotent, because arming twice would install four monitors and fire `onCancel` twice for one Escape.

Note what is deliberately *not* done: the monitors stay armed through the terminal states (`success`, `error`, and the rest) until the coordinator calls `dismiss()`. A result panel sitting on its auto-dismiss timer should still close when the user presses Escape.

### The picker's number keys cannot be swallowed, and that is a known tradeoff

The global monitor observes but cannot consume. When the style picker is up and the user presses `3`, this app picks the third style *and* the character reaches whatever app is frontmost. The only way to swallow it is to make the panel key, which brings back the activation failure described above and costs the selection. Losing the selection is fatal to the feature; a stray character is not.

Two things follow. The coordinator should capture the selection *before* the picker is shown, so a stray keystroke cannot alter the text being rewritten. And the digit handler checks `plainKeystroke(_:)` so that ⌘3 or ⌥3 in the app underneath is left alone and only a bare digit counts.

If you ever revisit this, the answer is not an activating panel. It is a `CGEventTap`, which needs its own permission and is a much larger change than it looks.

## Bottom centre, not the text caret

The obvious idea is to float the panel next to the text the user selected. Do not build it.

Caret anchoring needs `kAXBoundsForRangeParameterizedAttribute` to turn the selected character range into screen coordinates. That attribute depends on exactly the same range reporting that `Improve/Selection/AGENTS.md` documents as unreliable, and it inherits every one of those problems plus some of its own. Many applications do not implement the parameterized attribute at all. Chromium and Electron apps report it inconsistently, and their off-by-one range behavior lands the rectangle on the wrong character. Applications that do implement it can return an empty rect, a rect in the wrong coordinate space, or a rect for a line that is scrolled out of view, which places the panel above the top of the display or below the bottom of it. A panel the user cannot see is worse than a panel in a boring place, because the app looks broken rather than plain.

Bottom centre of the screen the mouse is on is always on screen, always the same place, and after a day of use the user's eye goes there without looking. That is worth more than proximity.

Two details of the geometry that are not arbitrary:

- The screen is chosen by **pointer location**, not `NSScreen.main`. `NSScreen.main` is the screen containing the key window, and this app deliberately never has a key window, so it is the wrong question to ask. The screen is captured once at `show()` into `anchorScreen` and held for the whole presentation, so a panel growing as text streams in cannot hop to another display because the user moved the mouse.
- The window origin is recomputed from the **bottom edge** on every resize. The panel grows upward and its bottom edge never moves. Anchor the top instead and the whole panel visibly crawls down the screen as the rewrite streams in.

Height is measured from the SwiftUI content at the fixed 460pt width, then clamped to 40% of the anchor screen's `visibleFrame`. Past that the content scrolls inside an `NSScrollView` instead of the window continuing to grow. A 40% cap on a laptop display is around 400pt, which is a lot of text, and a panel taller than that has stopped being an overlay.

The width is set as a constant constraint on the hosting view rather than pinned to the clip view, because this same measurement is about to resize the window and a constraint tied to the window's own width is unsatisfiable for one layout pass while that happens. The hosting view is also given its final width before being measured: the height of wrapped text is a function of the width it is laid out at, and measuring unconstrained reports the single-line height of a paragraph that will really wrap to eight lines.

The background lives in a separate hosting view pinned behind the scroll view rather than inside the scrolling content. If the background scrolled with the text, then in the one case that matters, a long rewrite that exceeds the cap, the rounded bottom corners would scroll up out of view and leave two square transparent notches at the bottom of the panel.

## Streaming updates are throttled to about one display frame

`update(_:)` coalesces `generating` states to roughly 16 ms. Everything else renders immediately.

A 4B model on Apple Silicon emits tokens faster than 60 Hz. Every `RewriteEvent` carries a full cumulative snapshot of the output so far, not a delta, so rendering each one re-lays out an entire growing paragraph of text dozens of times per second, remeasures it, and resizes the window. None of that work is visible: the display cannot show more than one frame per frame. The cost is real though, and it competes for the main thread with the decode loop feeding it.

Dropping an intermediate snapshot is free precisely because these are snapshots. The next one is a superset of the one that was skipped. This is the same property that repo-root `AGENTS.md` §3 gives as the reason the engine protocol is snapshot shaped, and this is the place where it pays for itself. If someone converts the engines to deltas, this throttle silently starts corrupting output, which is the second reason not to do that.

Two rules make the throttle safe:

1. **Only `generating` is eligible.** Terminal states, `applying`, `capturing`, and the picker all render at once. A terminal state must never sit behind a timer holding a stale spinner.
2. **A non streaming state cancels the pending flush.** Without that, a queued older snapshot could land after the terminal state and overwrite the result with a half finished paragraph.

The flush timer is added to `RunLoop.main` in `.common` mode. A default mode timer stops firing while the user holds a scroll gesture or an open menu, which would freeze the streaming text mid rewrite for as long as they hold it.

The throttle is in the controller and not in the view on purpose. It is a property of the boundary between the transaction and the screen, so it should be enforced once at that boundary rather than re-derived by every view that might want to show progress.

## Accessibility here is a requirement, not a polish pass

This panel is a small, translucent, briefly visible window full of text, placed over content it does not control. That is close to a worst case for legibility, so the settings the user has already told the system about are not optional.

`PanelAppearance` reads three values from `NSWorkspace` and every one of them changes what is drawn:

- **Reduce Motion** removes the state transition animation and suppresses indeterminate spinners. An indeterminate spinner animates forever, which is the exact thing the setting asks us not to do. A *determinate* progress bar is kept, because it carries position information rather than motion for its own sake, and the words in the header already say what is happening.
- **Reduce Transparency** swaps the material for an opaque window colour. Translucency over arbitrary underlying content is the single worst thing you can do to text contrast, and this window floats over arbitrary content by definition.
- **Increase Contrast** thickens the border, drops secondary label colour back to full label colour, and strips the tint from the state symbol. Under this setting the user has asked for legibility rather than visual hierarchy.

These are read from `NSWorkspace` rather than from the SwiftUI environment. The environment values are populated for views inside an application's normal window hierarchy, and this content lives in an `NSHostingView` inside a borderless panel that is never key and is not in a `WindowGroup`. `NSWorkspace` is where those environment values come from anyway, so reading the source directly removes a dependency that might or might not hold. It is sampled once per `show()` rather than observed, because the alternative is another observer whose lifetime has to be managed on the same paths that already manage the key monitors, and one thing that can leak is better than two. A user who flips a setting during a three second rewrite sees it applied on the next one.

**No state is signalled by colour alone.** Every case in `PanelState` supplies an SF Symbol and a sentence, and colour is applied last as decoration that can be deleted without losing information. A green check and a red cross at 14pt are the same grey glyph to a user with deuteranopia, and roughly one man in twelve has some form of it. `PanelState.symbolName`, `title`, and `detail` are a `switch` over every case with no `default`, so adding a case makes the compiler ask you for the words and the icon.

Accessibility labels are on every control. Two specific choices: the panel as a whole exposes `PanelState.accessibilityLabel` as its value, and the `generating` case deliberately leaves the streaming text *out* of that label, because VoiceOver restarts its utterance every time the value changes and would otherwise read the first three words of the rewrite over and over at token rate. The style picker rows read their number, because the number is a usable instruction and not decoration.

## Style picker

Numbered rows, driven by an `Int` in `PanelModel` that the key monitor moves. Keys 1 to 5 pick directly, arrows move the highlight, Return commits, Escape cancels. Mouse clicks work too, because a non-activating panel does receive mouse events without activating the app.

Only the first five rows get a digit. A sixth custom style is still reachable with the arrows and gets no number rather than a wrong one.

The selected row is marked by a background tint, a bolder name, *and* a chevron. The chevron is held at zero opacity rather than removed when not selected, so the row does not change width as the highlight moves.

## Things that will look like cleanups

- Making the panel a normal `NSWindow`, or dropping `.nonactivatingPanel`. Kills the selection. See the top of this file.
- Replacing the event monitors with `.onKeyPress`, `.keyboardShortcut`, or `@FocusState`. Compiles, previews correctly, does nothing when shipped.
- Leaving the monitors installed between transactions "to avoid the churn". Installing them costs nothing. Leaving them installed means this app watches every keystroke the user types all day.
- Removing the local monitor because "the global one covers it". It does not cover our own process.
- Rendering every streamed snapshot because "16 ms is premature optimisation". It is a per token full paragraph relayout competing with the decoder for the main thread.
- Letting a terminal state go through the throttle "for consistency". A queued snapshot then overwrites the final result.
- Following the caret with `kAXBoundsForRangeParameterizedAttribute`. Puts the panel offscreen on the apps where the range data is already known to be wrong.
- Treating Reduce Motion or Reduce Transparency as a nice to have. They are the reason the panel is readable for the people who need them most.

## Verified

Every file in this directory typechecks clean under Swift 6 strict concurrency against the built `RewriteCore` module:

```bash
cd Improve/Overlay
xcrun swiftc -typecheck -target arm64-apple-macos26.0 -swift-version 6 \
  -I ../../RewriteCore/.build/out/Products/Debug \
  PanelState.swift RewriteView.swift StylePickerView.swift FloatingPanelController.swift
```

That is a type check, not a run. Window behavior, monitor teardown, and the height measurement need a real app and a real second application to point at, so they are checked by hand once Task 5 exists.
