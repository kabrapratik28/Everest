# Contributing

## Before you write code, read one file

Every source directory has an `AGENTS.md` holding the decisions made there and
**why** — `CLAUDE.md` next to it is a one-line pointer and holds nothing. Read
the one for the directory you are changing. Most of what looks odd in this
codebase is written down there with the measurement that forced it, and a
change that undoes one of those will be asked to put it back.

The root [`AGENTS.md`](AGENTS.md) is the architecture doc. Two rules in it are
not negotiable:

**§0 — this codebase is test-driven.** No production code without a failing
test first. Not "tests after achieve the same goal", not "too simple to test".
A pull request that adds behaviour without a test that failed before it is
the one kind that gets closed rather than reviewed. Paste the failing run in
the PR description; a claimed pass with no observed failure is not evidence.

**§2 — docs are budgeted.** 150 lines at the root, 60 per directory. Over the
budget means cut something or split the directory, never append. If your
change alters behaviour a doc describes, change the doc in the same commit.

## Setup

```bash
brew install xcodegen
git clone https://github.com/kabrapratik28/Everest.git && cd Everest
xcodegen generate
open Everest.xcodeproj
```

The app runs on macOS 14 or later. **Building it needs Xcode 26**, which is a separate requirement from what it ships against: the `FoundationModels` path compiles only against the 26 SDK and is runtime-guarded for everyone below it. Xcode 26 does not
install the Metal toolchain by default and MLX compiles ~40 `.metal` kernels
during a normal build, so also run:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Re-run `xcodegen generate` after adding or renaming any file. The project file
is generated and not committed.

You do **not** need an Apple Developer account. A clean clone signs ad-hoc.
The cost is that macOS re-asks for Accessibility permission after every build,
because it binds that grant to the code signature; `Everest/Signing.xcconfig`
explains how to avoid it with your own certificate.

## Running the tests

```bash
cd EverestKit && swift test
```

That runs everything testable, across five targets, and needs no app, no
permissions and no model. It is what CI would run. No count here on purpose:
a number in a doc goes stale silently and the runner already prints one.

**`swift test` does not compile the app target.** `Everest/` is Xcode-only, so
a break in `AppDelegate.swift` or the SwiftUI screens is loud to nobody until
someone builds in Xcode. If you touch anything under `Everest/`, build the app
too and say in the PR that you did.

Some things genuinely cannot be unit-tested here: Accessibility against a live
app, a multi-gigabyte download, Metal inference. Those are tested at the
nearest seam and the rest is in [`docs/MANUAL-CHECKS.md`](docs/MANUAL-CHECKS.md).
Add to that list rather than writing a test that asserts nothing.

## What makes a good pull request

- **One thing.** A behaviour change plus a refactor plus a doc sweep is three
  reviews wearing a trenchcoat.
- **The failing test, pasted.** Red first, then green.
- **A reason, not an inventory.** "Restore is gated on `changeCount` because a
  fixed delay races the user and eats what they copied" is useful; "improved
  clipboard handling" is not.
- **Say what you measured and what you assumed.** Claims about macOS
  behaviour in this codebase are stamped with when they were measured,
  because a documented measurement is the kind of error no reader can catch.
- **Privacy claims are tested strings.** If you change what the app says about
  where the user's text goes, `AppCoreTests` will tell you, and
  [`PRIVACY.md`](PRIVACY.md) needs the same change.

## Scope

This is a small, opinionated app and it is going to stay one. Before building
something large, open an issue and ask — §1 of the root `AGENTS.md` is a YAGNI
rule with teeth, and "no abstraction with one implementation" applies to
contributions too.

Bug reports, a fix for one of the apps in
[`docs/MANUAL-CHECKS.md`](docs/MANUAL-CHECKS.md) that Everest handles badly,
and anything on [`docs/PUNCH-LIST.md`](docs/PUNCH-LIST.md) are all welcome
without asking first.

## Licence

By contributing you agree your work is licensed under the MIT licence in
[LICENSE](LICENSE) — inbound equals outbound. There is no CLA.
