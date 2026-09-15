# Releasing, and how users get updates

Everest is distributed outside the Mac App Store, because it cannot be in it:
sandboxed, `AXUIElementSetAttributeValue` does nothing and `AXIsProcessTrusted()`
is permanently false (root `AGENTS.md` §7). So distribution and updates are ours
to run.

## Blocking today

**The signing certificate on this machine is `Apple Development`. That cannot
ship.** Measured:

```
$ spctl -a -vvv -t exec /Applications/Everest.app
/Applications/Everest.app: rejected
origin=Apple Development: kabrapratik28@gmail.com
```

`rejected` is what every downloader would hit. Gatekeeper refuses a
development-signed app on any Mac but the one that built it.

**What is needed: a `Developer ID Application` certificate**, which requires
the Apple Developer Program at **$99/year**. It is the same membership either
way — the App Store is not an option here, so the fee buys notarisation and
nothing else. There is no free path that avoids the "Apple could not verify"
dialog; `xattr -d com.apple.quarantine` works but asking strangers to run it is
not a distribution strategy.

**Second blocker:** `project.yml` hardcodes one certificate's SHA-1, so a clean
clone does not build elsewhere. Pinning is deliberate — Accessibility permission
is bound to the code signature, and an ad-hoc signature changes every build — but
the value must move out of the committed file before anyone else can contribute.

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
