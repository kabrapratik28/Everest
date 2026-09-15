# Releasing, and how users get updates

Everest is distributed outside the Mac App Store, because it cannot be in it:
sandboxed, `AXUIElementSetAttributeValue` does nothing and `AXIsProcessTrusted()`
is permanently false (root `AGENTS.md` §7). So distribution and updates are ours
to run.

## What Gatekeeper does today

The signing certificate on this machine is `Apple Development`. Measured:

```
$ spctl -a -vvv -t exec /Applications/Everest.app
/Applications/Everest.app: rejected
origin=Apple Development: <your name> (<team id>)
```

`rejected` is what every downloader hits. It does **not** mean the app cannot
be distributed — it means the user must approve it once by hand. Whether that
is acceptable is the $0 question below, not a technical blocker.

**A real blocker either way:** `project.yml` hardcodes one certificate's SHA-1,
so a clean clone does not build elsewhere. Pinning is deliberate — Accessibility
permission is bound to the code signature — but the value must move out of the
committed file before anyone else can contribute.

## The $0 route, and the one thing it must not get wrong

Launching free on GitHub Releases is viable and is the right first move: it
tests whether anyone wants this before spending anything. Developers are used
to it. macOS will say "Apple could not verify Everest is free of malware", and
the user goes to **System Settings ▸ Privacy & Security ▸ Open Anyway** once.
Since macOS 15 the old right-click-Open shortcut is gone, so that pane is the
only path — the README must say so in those words.

**But the build must be signed with the Apple Development certificate, not
ad-hoc.** This is specific to Everest and it is not optional. Measured:

```
Development-signed:  identifier "com.kabrapratik.Everest" and anchor apple
                     generic and certificate leaf[subject.CN] = "Apple
                     Development: …"                              ← stable
ad-hoc (codesign -s -):  cdhash H"f8c78ba8…"                      ← per build
```

macOS binds Accessibility permission to the designated requirement. An ad-hoc
DR is a content hash, so **every update would silently revoke the permission
the app cannot work without**, and the user would have to find it in System
Settings again each time. A Development-signed DR is identifier plus
certificate, which survives rebuilds and renewals. Gatekeeper still refuses it
without notarisation — that is the one-time Open Anyway — but TCC accepts it.

**Untested and worth checking before any public release:** that a
Development-signed build runs at all on a Mac that is not this one. The
signature is valid and Open Anyway should cover it, but development
certificates are not intended for distribution and this has not been
confirmed on second hardware.

**The tension with CI.** Building releases from public source via GitHub
Actions is good for trust, and it conflicts with the above: CI cannot sign
with the Development certificate unless the certificate and its password go
into repository secrets. An unsigned CI build brings back the per-build
cdhash. Pick one — reproducibility or a stable permission grant — or sign
locally and let CI only verify.

### Guiding the user through it

Nothing in the app can help before first launch, because Gatekeeper prevents
the app from running at all. The only surfaces that exist at that moment are
the download page and the disk image. So:

- **A `.dmg` with a background image** showing "drag to Applications" and the
  three Open Anyway steps. This is the only in-install guidance possible.
- **Release notes and README** repeating it in the same words macOS uses, so
  the sentence the user sees on screen matches the one they were given.

Everything after that first launch is already handled: onboarding walks
through the Accessibility grant and polls for it, so the user is not left
guessing.

### When $99 becomes worth it

When the Open Anyway step costs more in lost users than the fee. At a few
hundred installs that is plausible; before the first one it is not. Note the
fee is not avoidable later by open-sourcing — Apple's waiver covers
nonprofits, accredited schools and government, not individual open-source
developers.

## Versioning

`project.yml` holds both numbers:

- `MARKETING_VERSION` — what users see. Semantic: `1.0.0`, `1.0.1`, `1.1.0`.
- `CURRENT_PROJECT_VERSION` — a monotonic build number. **Must increase on
  every release**; Sparkle compares it, not the marketing string.

Currently `0.1.0` / `1`.

## Cutting a release

1. Bump both numbers in `project.yml`, commit, tag `v1.0.0`.
2. Build Release, signed with **Developer ID Application** and Hardened Runtime
   on (`com.apple.security.cs.allow-jit` is already required for MLX).
3. Notarise and staple:
   ```bash
   xcrun notarytool submit Everest.zip --keychain-profile "AC" --wait
   xcrun stapler staple Everest.app
   ```
   Stapling matters: without it a first launch offline fails the check.
4. Package as `.dmg`, attach to a GitHub Release.
5. Sign the appcast entry and publish it (below).
6. Verify on a Mac that has never built the app: `spctl -a -vvv -t exec` must
   say **accepted**.

## Automatic updates — Sparkle

The answer to "I fix a bug tomorrow, how do existing users get it": **[Sparkle
2](https://sparkle-project.org)**, the standard for non-App-Store Mac apps. Not
built yet; this is the shape.

**One-time setup**

- Add the `Sparkle` SPM dependency and a `SPUStandardUpdaterController`.
- Generate an EdDSA key pair with Sparkle's `generate_keys`. **The private key
  never leaves the keychain and is never committed** — it is what stops anyone
  else shipping an "update" to your users.
- Put `SUFeedURL` and `SUPublicEDKey` in `Info.plist`.

**Every release**

- `generate_appcast` over the release folder produces `appcast.xml` with the
  version, release notes, download URL, length and EdDSA signature.
- Host `appcast.xml` at a stable URL — GitHub Pages is free and sufficient.
- Sparkle checks it on a schedule, offers the update, verifies the signature,
  and installs on quit.

**Why signatures are not optional.** The feed is the mechanism by which code
arrives on a user's machine. An unsigned appcast over a compromised connection
is an arbitrary-code-execution channel. Sparkle refuses an update whose EdDSA
signature does not verify, and that is the whole security model.

**One consequence worth planning for:** Accessibility permission is bound to the
code signature, and a Sparkle update replaces the bundle. Re-signing with the
*same* Developer ID keeps the designated requirement stable, so the grant should
survive — **but that has not been tested here and must be verified on the first
update**, because a silent permission loss after an auto-update is the worst
possible first impression. See `docs/MANUAL-CHECKS.md`.

## Before the first public release

- `Developer ID Application` certificate and notarisation working.
- Signing identity out of `project.yml`.
- Everything in `docs/PUNCH-LIST.md` and the P0s in `docs/EXTERNAL-AUDIT.md`.
- A first-run pass on a Mac that has never run Everest — the download path is
  invisible on a machine that already has the weights.
- Decide the open questions in `docs/OPEN-DECISIONS.md`; two of them change
  defaults that would be awkward to reverse once strangers are running the app.
