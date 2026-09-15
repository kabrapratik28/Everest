# App — wiring, and nothing else

Construction, callbacks, windows. **No decisions.** Every branch this app makes
lives in `EverestKit/Sources/AppCore`, which has a test runner; a branch here
has none, and that is what forced this project's rebuild. If you are about to
write an `if` in `AppDelegate`, it belongs in `AppCore`. Nothing here is
covered by `swift test` either — `KeyboardShortcuts` is not in the SwiftPM
graph — which is the second reason to keep these files empty of logic.

## Decisions that live here anyway

**Status item is a template SF Symbol**, `mountain.2.fill` falling back to
`sparkles`, `isTemplate = true`. Never `AppIcon.icns`: at 18pt the gradient
turns to mush, and a fixed-colour image cannot follow light/dark or invert when
highlighted. See `Everest/Resources/AGENTS.md`.

**Menu items set `target` explicitly.** `addItem(withTitle:action:)` leaves it
nil, sending the action down a responder chain this app has no key window to
start — every item would be permanently greyed out.

**Still no `keyEquivalent`** — bindings show as an `NSMenuItemBadge`, trailing
text only. A key equivalent is a second, separately-editable copy of a hotkey
the user can re-record, stale the moment they do; `menuWillOpen` re-reads
`KeyboardShortcuts.getShortcut(for:)` on every open instead. Rendering stays
here: key code to character needs the active keyboard layout, and a rival
formatter could disagree with the recorder. `MenuCommand.hotkey` picks which.

**Settings opens with `OpenSettingsAction`, never `showSettingsWindow:`.** On
macOS 26.6.2 neither that selector nor `showPreferencesWindow:` exists on
`NSApplication` or SwiftUI's `AppKitApplication`, yet `sendAction` returns
`true` — the old call reported success and did nothing. The action reads only
from a SwiftUI scope, so the scene body hands it to the delegate. **Activate
first**, or the window is visible but not key, behind the app they came from.

**`AppPresence.start()` runs in `applicationDidFinishLaunching`**: `LSUIElement`
pins every launch to `.accessory`, so the ⌘Tab preference would silently reset.

**Onboarding is an `NSWindow`, not a SwiftUI `Window` scene.** A scene restores
itself on every launch, which is wrong for setup the user has finished.

**Accessibility is opened by URL**, not `AXIsProcessTrustedWithOptions`'s
prompt: that dialog appears once per app signature, so a user who dismissed it
never gets it back, and its button opens the same pane anyway.

**The exclusion list is passed into every capture.** `capture:` assigns
`SelectionCoordinator.excludedBundleIDs` before each read, so an app the user
excluded thirty seconds ago is excluded now. Not assigned once at launch.

**`Logger` subsystem from `Bundle.main.bundleIdentifier`, never a literal** — a
drifting literal fails invisibly, the app runs and `log stream` returns
nothing. **Nothing selected or generated is ever logged**; `OSLog` persists.

## Not verified here

`swiftc -parse` only; type-checking needs `xcodegen generate` and the app build.

**Manual check, unresolved:** `onKeyDown` fires while the chord is still
physically held, and capture rung 9 posts a synthetic ⌘C. Confirm a
clipboard-fallback app (a terminal, a PDF) still captures with it held. If not,
`onKeyUp` is the fix.
