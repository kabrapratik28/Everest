# Everest

Select text in any Mac app, press `⌥R`, and a locally-generated rewrite streams into a floating panel and replaces your selection.

The model runs on your Mac. Nothing is sent to a server, and it works with networking off.

**One honest exception.** Where macOS will not let Everest read a selection directly — terminals, PDFs, Google Docs, Sublime Text — it falls back to the system clipboard, and anything on the system clipboard is eligible for Universal Clipboard if Handoff is on. There is no API to opt out of that. Turn Handoff off in System Settings ▸ General if it matters to you.

**Requirements:** macOS 26 or later, Apple Silicon. Roughly 4 GB free for the model.

## Install

Download the latest `.dmg` from [Releases](../../releases), drag Everest to Applications, and launch it.

On first run Everest asks for Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility) and then downloads the rewrite model — about 2.3 GB, with a progress bar. **The model is not bundled in the app.**

## Use

| Key | Does |
|---|---|
| `⌥R` | Quick Improve. One prompt, one rewrite. |
| `⌥⇧R` | Choose Style, then rewrite. |
| `Esc` | Cancel an in-flight rewrite. |

Both shortcuts are configurable in Settings ▸ General.

**Where it replaces in place:** native text fields, browsers, editors, chat apps, and — via a verified paste — editors that expose nothing to Accessibility, such as Sublime Text.

**Where it hands you the clipboard instead:** terminals, where a paste goes to the prompt rather than replacing a selection, and PDFs and ordinary web prose, which take no paste at all. The panel stays open and tells you.

**Never:** password and secure fields. Everest refuses before reading, and re-checks immediately before any synthetic copy.

### Why `⌥R`

A global hotkey beats the frontmost app, so the default decides what Everest takes away from every app on your Mac.

- `⌘`+letter is a formatting command somewhere — `⌘I` Italic, `⌘U` Underline, `⌘B` Bold, `⌘K` link.
- `⌃`+letter is worse: Cocoa text views carry emacs bindings and terminals own `⌃C`/`⌃D`/`⌃Z`/`⌃R`.
- `⌥R` costs one character, `®`.

If you rebind, avoid `⌥I`, `⌥E`, `⌥U` and `⌥N` — those are dead keys, and binding one globally breaks accented typing. Settings tells you which character a binding will cost you.

## Build from source

```bash
brew install xcodegen          # once
git clone <this repo> && cd Everest
xcodegen generate
open Everest.xcodeproj         # then ⌘R
```

```bash
cd EverestKit && swift test    # all logic, no app needed
```

**Signing.** `project.yml` currently hardcodes one developer certificate, so a clean clone will not build on another Mac without editing it. This is a known limitation — see `docs/PUNCH-LIST.md`. The certificate is pinned rather than ad-hoc because macOS binds Accessibility permission to the code signature, and an ad-hoc signature changes on every build, forcing you to re-grant permission each time.

Xcode 26 needs the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

## Contributing

Every source directory has an `AGENTS.md` holding the decisions made there and **why**. Read the one for a directory before editing it. `CLAUDE.md` files are one-line pointers to them and hold no content.

Two conventions are not negotiable and are explained in the root `AGENTS.md`:

- **This codebase is test-driven.** No production code without a failing test first.
- **Docs are budgeted** — 150 lines at the root, 60 per directory. Over means cut, or split the directory.

`docs/WORKING-RULES.md` collects the review practices that came out of building this, including five distinct ways to get a passing test run that means nothing.

## Licence

MIT. See [LICENSE](LICENSE).
