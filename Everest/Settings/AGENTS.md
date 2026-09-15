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

**Preset fields are bordered, with a caption above.** Borderless in a `Form`,
a populated field reads as static text; and in the Styles rows `Form`'s label
column never applies, so the name was a placeholder that vanished on contact.

**The draft is kept apart from the stored value** so trimming does not fight
typing: a trailing space stays visible mid-word, and emptying a field whose
rule refuses blanks keeps the last good value. It re-syncs when the value moves
from elsewhere, which is what makes "Reset to default" visible in a touched one.

**The Model tab's row is the radio button.** It used to draw one beside a
separate "Use" button, so the control that looked like a radio was a picture.
The row is a plain `Button` carrying `.isSelected`, and
`ModelSettingsModel.select` is the only thing that moves the engine.

**The ⌘Tab toggle says "Dock and app switcher".** macOS has one setting for
both — the activation policy — so a switch promising only ⌘Tab would deliver a
Dock icon the user never asked for and could not find the switch to remove.

**Permission state is polled every second**, in General and onboarding: the
user grants it in another process with this window open, so a value read once
keeps saying "Not granted" and the only way out is quitting mid-setup.

**Styles reorder with explicit buttons, not `onMove`/`onDelete`** — those are
`List` affordances that in a macOS `Form` do nothing, or want an `EditButton`
macOS does not have. Delete goes by `id`, never a captured index.

**`SMAppService` failures put the toggle back and say why** — it throws after
the switch has moved, and one that springs back silently reads as broken.

**The capability table is shown before the model step.** "Works anywhere" is
true of reading a selection and false of writing one. Meeting that limit first
in Ghostty, mid-sentence, reads as a broken app; announced up front it is a
tool handing you the clipboard. The password row is the other half — the
refusal is the app working, and a user not told tries somewhere less careful.

**The table says the words as well as colouring them.** A green tick and a red
cross at this size are the same grey glyph to one man in twelve.

**The Model tab's test box has no `ReplacementService` and no snapshot**, so no
path leads from it into a document or onto the pasteboard. It goes through the
same `PromptBuilder` and `OutputValidator` a hotkey press does; a box that
skipped either would demonstrate something the app does not do.
