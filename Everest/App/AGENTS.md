# App — wiring, and nothing else

Construction, callbacks, windows. **No decisions.** Every branch this app makes
lives in `EverestKit/Sources/AppCore`, which has a test runner; a branch here
has none, and that is what forced this project's rebuild. If you are about to
write an `if` in `AppDelegate`, it belongs in `AppCore`.

Nothing in this directory is covered by `swift test` — `KeyboardShortcuts` is
not in the SwiftPM graph, so these files compile only in the Xcode app target.
That is the second reason to keep them empty of logic.

## Decisions that live here anyway

**Status item is a template SF Symbol**, `mountain.2.fill` falling back to
`sparkles`, `isTemplate = true`. Never `AppIcon.icns`: at 18pt the gradient
turns to mush, and a fixed-colour image cannot follow light/dark or invert when
the item is highlighted — it stays a dark smudge on a dark bar. See
`Everest/Resources/AGENTS.md`.

**Menu items set `target` explicitly.** `addItem(withTitle:action:)` leaves it
nil, which sends the action down the responder chain; this app has no key
window to start one, so every item would be permanently greyed out.

**No `keyEquivalent` on the two rewrite menu items.** The real bindings are
global `KeyboardShortcuts` hotkeys. A menu key equivalent is a second,
separately-editable copy that goes stale the moment the user rebinds, showing
`⌘I` in the menu while the hotkey is `⌥R`.

**Onboarding is an `NSWindow`, not a SwiftUI `Window` scene.** A scene restores
itself on every launch, which is wrong for setup the user has finished.

**Accessibility is opened by URL**, not `AXIsProcessTrustedWithOptions`'s
prompt: that dialog appears once per app signature, so a user who dismissed it
can never get it back, and its button opens the same pane anyway.

**The exclusion list is passed into every capture.** `capture:` assigns
`SelectionCoordinator.excludedBundleIDs` before each read, so an app the user
excluded thirty seconds ago is excluded now. Not assigned once at launch.

**`Logger` subsystem from `Bundle.main.bundleIdentifier`, never a literal** — a
drifting literal fails invisibly, the app runs and `log stream` returns
nothing. **Nothing selected or generated is ever logged**; `OSLog` persists.

## Not verified here

`swiftc -parse` only. Type-checking needs `xcodegen generate` and the app
build, which are not this directory's to run.

**Manual check, unresolved:** `onKeyDown` fires while ⌘ is still physically
held. Capture rung 9 posts a synthetic ⌘C, so confirm a clipboard-fallback app
(a terminal, a PDF) still captures correctly with the chord held. If it does
not, `onKeyUp` is the fix.
