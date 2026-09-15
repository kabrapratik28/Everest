# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security ▸ Report a
vulnerability** on this repository. That opens a private advisory only the
maintainers can see. Please do not open a public issue for anything in the
list below.

Expect a first reply within a week. There is no bounty; this is one person's
side project.

## Supported versions

The latest release only. There are no maintenance branches.

## What is in scope

Everest holds Accessibility permission, which on macOS means it can read and
write the focused text of every running app. Anything that widens or abuses
that is the interesting class of bug:

- Reading a selection from a field Everest should have refused — a password
  field, a secure-input host, or an app on the user's exclusion list.
- Writing into an app or a field the user did not select into.
- Getting the clipboard restored to the wrong contents, or not restored, in a
  way that leaks what the user had copied.
- A rewrite reaching the network, a log, or disk. Everest is local-only and a
  path that breaks that is a vulnerability, not a feature request.
- Prompt injection that escapes `PromptBuilder.safetyFrame` — selected text
  that gets treated as instructions rather than as content.
- Anything in the update path once Sparkle ships: an unsigned or
  wrongly-verified appcast is arbitrary code execution.

## What is out of scope

- **The model writing something wrong, biased, or unwanted.** It is a language
  model. That is a quality issue, so open a normal issue.
- **Handoff syncing the clipboard to your own devices.** Documented in
  [PRIVACY.md](PRIVACY.md). No app can opt out of it; a report that Everest
  should is not actionable.
- **Clipboard-history apps recording a rewrite despite the transient marker.**
  `org.nspasteboard.TransientType` is a convention those apps choose to
  honour, not something Everest can enforce.
- **Gatekeeper refusing an unnotarised build.** Known and documented in the
  README; it is a cost decision, not a defect.
- Findings that require the attacker to already have code execution as the
  user, or physical access to an unlocked Mac.

## Hardening already in place

Worth knowing before you report, so you can tell a gap from a design choice:

- Not sandboxed, deliberately — a sandboxed process cannot use the
  cross-process Accessibility API at all.
- Hardened Runtime on, with `com.apple.security.cs.allow-jit` because MLX
  needs it.
- Secure fields are checked twice: by subrole before reading, and by
  `IsSecureEventInputEnabled()` again immediately before any synthetic copy.
- The prompt's safety frame is not user-editable, on purpose. A user-editable
  injection guard is not a guard.
- Model repositories are pinned to exact revisions, and the Swift package
  dependencies to exact versions.
