# Overlay/Review: the pane that waits for an answer

The review state: the rewrite shown before anything reaches the document, edited or read as tracked changes, answered with ↩ or esc. Split out of `Overlay/` because that directory's doc was at its budget, and these decisions share nothing with streaming or the picker.

## The changes view is a word diff, and it never re-spaces

`WordDiff` splits on words *with* their trailing whitespace and compares them without it, so a changed line break is not a changed word, and the kept and added runs join back into the rewrite byte for byte. Built on the stdlib's `difference(from:by:)`; no dependency. Removed runs come before added runs at each change, the order people read track changes in.
