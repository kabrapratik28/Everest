# Everest

Select text in any Mac app, press `⌥R`, and a locally-generated rewrite streams into a floating panel and replaces your selection.

The model runs on your Mac and nothing is sent to a server — it works with networking off. One honest exception: where macOS will not let Everest read a selection directly (terminals, PDFs, Google Docs) it falls back to the system clipboard, and anything on the system clipboard is eligible for Universal Clipboard if you have Handoff on. There is no API to opt out of that; turn Handoff off in System Settings ▸ General if it matters to you.

macOS 26+, Apple Silicon only.

## Build

```bash
brew install xcodegen          # once
cd ~/Desktop/Everest
xcodegen generate
open Everest.xcodeproj         # then ⌘R
```

First launch asks for Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility), then downloads the rewrite model with a progress bar. The model is roughly 2.3 GB and is **not** bundled in the app.

## Tests

```bash
cd EverestKit && swift test
```

## Hotkeys

| Key | Does |
|---|---|
| `⌥R` | Quick Improve. One prompt, one rewrite. |
| `⌥⇧R` | Choose Style, then rewrite. |
| `Esc` | Cancel an in-flight rewrite. |

Both are configurable in Settings. Option is used because a global hotkey beats the frontmost app, so the default decides what Everest takes away from every app on the Mac. `⌘`+letter is a formatting command everywhere (`⌘I` Italic, `⌘U` Underline, `⌘B` Bold, `⌘K` link); `⌘⇧I` is Web Inspector in three browsers. `⌃`+letter is worse — Cocoa text views carry emacs bindings and terminals own `⌃C`/`⌃D`/`⌃Z`/`⌃R`, and terminals are a first-class target here. `⌥R` costs one character, `®`. Avoid `⌥I`, `⌥E`, `⌥U` and `⌥N` if you rebind: those are dead keys and binding one breaks accented typing.

Replacement works in native text fields, browsers, editors and chat apps. In Terminal, PDFs and ordinary web prose there is no editable buffer, so the result is placed on the clipboard instead and the panel says so.

## Where the decisions live

`AGENTS.md` at the repo root, and one in every source directory. Read the one for a directory before editing it. `CLAUDE.md` files are pointers to them and hold no content of their own.
