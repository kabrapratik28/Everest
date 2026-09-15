# Settings and onboarding — layout only

Two SwiftUI files. Every rule they enforce is in `AppCore`; a view here calls
`PresetEdit`, `ExclusionEdit`, `OnboardingModel` or `ModelSettingsModel` and
renders the answer. Nothing in this directory is reachable from `swift test`.

## Decisions

**`PromptBuilder.safetyFrame` is not on this screen and must never be.** Only
`Preset.instruction` is editable. The frame is the prompt-injection guard, and
a user-editable guard is not one — selected text saying "ignore previous
instructions" is exactly what it exists to contain.

**A blank instruction is refused, not saved.** It would send the frame, a blank
line and the user's text, leaving the model to invent a task that then lands in
their document. `InstructionField` keeps a separate draft so trimming does not
fight typing: a trailing space stays visible mid-word, and emptying the field
leaves the last good value stored.

**Permission state is polled every second**, in both General and onboarding.
The user grants it in System Settings, in another process, with this window
open; a value read once keeps saying "Not granted" after they have granted it,
and the only way out would be quitting an app they have not finished setting
up.

**Styles reorder with explicit buttons, not `onMove`/`onDelete`.** Those are
`List` affordances. In a macOS `Form` they either do nothing or want an
`EditButton`, which macOS does not have.

**`SMAppService` failures put the toggle back and say why.** It throws after
the switch has already moved, and a switch that silently springs back reads as
a broken control.

**The capability table is shown before the model step, not after.** "Works
anywhere" is true of reading a selection and false of writing one. Meeting that
limit for the first time in Ghostty, mid-sentence, reads as a broken app; the
same behaviour announced up front is a tool handing you the clipboard. The
password row is the other half — the refusal is the app working, and a user who
is not told assumes it failed and tries somewhere less careful.

**The table says the words as well as colouring them.** A green tick and a red
cross at this size are the same grey glyph to one man in twelve.

**The Model tab's test box has no `ReplacementService` and no snapshot**, so
there is no path from it into a document or onto the pasteboard. It goes
through the same `PromptBuilder` and `OutputValidator` a hotkey press does; a
box that skipped either would demonstrate something the app does not do.
