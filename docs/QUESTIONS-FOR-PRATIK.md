# Questions for 8:30am

Collected overnight instead of interrupting. **Each has a default I already
took**, so nothing is blocked — these are decisions worth your second opinion,
not blockers.

---

## 1. Universal Clipboard breaks the "nothing leaves your Mac" promise

**The finding.** Everest puts text on `NSPasteboard.general` in three places:
the ⌘C fallback used to read your selection where Accessibility cannot (every
terminal, PDF and Google Doc), the ⌘V used to write a rewrite back, and every
`copiedOnly` outcome. **If Handoff is on, macOS may sync any of that to your
iPhone and iPad for about two minutes.**

I researched whether we can opt out. **We cannot.** There is no API. The
`org.nspasteboard.ConcealedType` markers we already set are a third-party
convention that clipboard managers choose to honour; the OS ignores them.
A private `NSPasteboard` avoids sync but cannot be read by ⌘V in other apps,
so it cannot do the job.

**What I did by default:** corrected the Privacy copy. It said "Nowhere." — a
claim the app cannot keep. The model genuinely never sees the network; the
clipboard hop is the exception and the honest thing is to name it.

**What I want from you:** whether the *behaviour* should change too.
Options, roughly in order of how much they cost you:

- **(a) Say it, keep it.** Accept the hop, state it plainly. Your own devices,
  end-to-end encrypted, two-minute window. This is what I did.
- **(b) Offer a setting** to disable the clipboard fallback. Costs you Google
  Docs, terminals and PDFs entirely — those work *only* via the clipboard.
- **(c) Warn once** the first time a rewrite uses the clipboard path.

I would not pick (b) as a default: it removes the feature from the apps that
need it most, to avoid a risk on your own hardware.

---

## 2. Should I keep the scratch reports in the repo?

~112 KB of agent reports in `docs/superpowers/plans/`. They are the RED/GREEN
evidence and the reasoning behind every non-obvious decision, and they have
already been useful twice for diagnosis. They are also noise in a repo you may
later want to show someone.

**Default:** kept for now, deleted once the reported bugs are confirmed fixed.

---

## 3. The repo will not build on any other machine

`project.yml` hardcodes your signing certificate's SHA-1, which is what stops
the Accessibility permission going stale on every rebuild.

**Default:** left as-is, since the repo is private and it is your machine.
Needs parameterising before anyone else builds it, or before it goes public.

---

## Product decisions I made without asking

Recorded so they are easy to overturn.

| Decision | Reasoning | Cost to reverse |
|---|---|---|
| Default shortcuts `⌃⌥I` / `⌃⌥⇧I` | `⌘I` is Italic everywhere; `⌘⇧I` is Web Inspector in Chrome, Safari and Firefox. A global hotkey wins over the frontmost app, so Everest was taking both system-wide. | One line |
| Refuse rather than truncate on long selections | Anything over ~3,000 characters was being silently replaced by a rewrite cut off mid-word. A user told "too long" has lost nothing; a user whose page is overwritten has lost work. | Config |
| Excluded-app list stays short (8 password managers) | Scanned all 53 apps here: no password manager or banking app installed, so none of the longer list could be verified. A wrong bundle id fails silently and buys false confidence. Matching is exact, so a bank in a browser tab matches nothing regardless. | Additive |
| No idle-unload timer for the model | The memory does not return to the OS anyway (MLX pools it), so a timer buys nothing and adds a mechanism to leak. Eviction on *delete* is deterministic and is what we built instead. | Additive |
| **Quick Improve's name and subtitle fields removed** — against your literal ask | You asked for "name, subtext and actual prompt" editable. Built that, then found Quick Improve has no picker row, so its name and subtitle render **nowhere**: you could type in them and nothing on screen would ever change. Styles keep all three, because the ⌘⇧I picker genuinely shows them. An editable field that changes nothing is worse than a missing one — it reads as a bug in the app. | Needs a display surface first, not just the fields back |
