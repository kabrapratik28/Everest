# Everest

Select text in any Mac app, press `⌘I`, and a locally-generated rewrite streams into a floating panel and replaces your selection. Nothing leaves the machine.

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
cd RewriteCore && swift test
```

## Hotkeys

| Key | Does |
|---|---|
| `⌘I` | Quick Improve. One prompt, one rewrite. |
| `⌘⇧I` | Choose Style, then rewrite. |
| `Esc` | Cancel an in-flight rewrite. |

Both are configurable in Settings. `⌘I` shadows Italic in editors while the app is running, which is the documented tradeoff of the requested default.

Replacement works in native text fields, browsers, editors and chat apps. In Terminal, PDFs and ordinary web prose there is no editable buffer, so the result is placed on the clipboard instead and the panel says so.

## Where the decisions live

`AGENTS.md` at the repo root, and one in every source directory. Read the one for a directory before editing it. `CLAUDE.md` files are pointers to them and hold no content of their own.
