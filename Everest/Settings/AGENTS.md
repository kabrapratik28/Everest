# Settings and onboarding — layout only

Two SwiftUI files, neither reachable from `swift test`. Every rule they
enforce is in `AppCore`; a view here calls it and renders the answer.

## Decisions

**`PromptBuilder.safetyFrame` is not on this screen and must never be.** A
style's name, subtitle and instruction are the user's; the frame is not. It is
the prompt-injection guard, and a user-editable guard is not one — selected
text saying "ignore previous instructions" is what it contains.

**`PresetField` takes its rule as a parameter, because the three differ.** A
blank instruction sends the frame, a blank line and the user's text, leaving
the model to invent a task that lands in their document. A blank name leaves a
style the Choose Style picker cannot label or announce. A blank subtitle is
fine — the Add button already makes one. Rules are `PresetEdit`, in `AppCore`.

**Preset fields are bordered, with a caption above.** Borderless in a `Form` a
populated field reads as static text, and `Form`'s label column never applies
in the Styles rows, so the name was a placeholder that vanished on contact.

**The draft is kept apart from the stored value** so trimming does not fight
typing: a trailing space stays visible mid-word, and emptying a field whose rule
refuses blanks keeps the last good value. It re-syncs on an outside change,
which is what makes "Reset to default" visible in a touched field.

**The Model tab's row is the radio button.** It used to draw one beside a
separate "Use" button, so the control that looked like a radio was a picture.
The row is a plain `Button` carrying `.isSelected`, and
`ModelSettingsModel.select` is the only thing that moves the engine.

**The ⌘Tab toggle says "Dock and app switcher".** One activation policy drives
both, so promising only ⌘Tab delivers an unasked-for Dock icon and no way back.

**Permission state is polled every second**, in General and onboarding: it is
granted in another process with this window open, so a value read once says
"Not granted" forever and the only way out is quitting mid-setup.

**Styles reorder with explicit buttons, not `onMove`/`onDelete`** — those are
`List` affordances that in a macOS `Form` do nothing, or want an `EditButton`
macOS does not have. Delete goes by `id`, never a captured index.

**`SMAppService` failures put the toggle back and say why** — it throws after
the switch moves, and one springing back silently reads as broken.

**Onboarding is three steps; the capability grid was cut.** Seven rows
between the permission and the model, read before the user had seen the app
work — friction everyone paid to warn a few. Its two `AppCore`-pinned strings
had to keep a home and neither may be dropped: `passwordPromise` onto the
permission step, which is where that access is being asked for, and
`exclusionCaveat` onto Settings ▸ Privacy beside the list it describes.

**Continue is `model.canAdvance`, with `model.continueHint` beside it.** Two
different things hold the model step; a grey button naming neither read as broken.

**The Model tab's test box has no `ReplacementService` and no snapshot**, so no
path leads from it into a document or onto the pasteboard. It goes through the
same `PromptBuilder` and `OutputValidator` a hotkey press does; a box that
skipped either would demonstrate something the app does not do.
